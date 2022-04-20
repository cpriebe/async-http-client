//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import AsyncHTTPClient
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOSSL
import XCTest

class HTTPRequestStateMachineTests: XCTestCase {
    func testSimpleGETRequest() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody]), nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
    }

    func testPOSTRequestWithWriterBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0]))
        let part1 = IOData.byteBuffer(ByteBuffer(bytes: [1]))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: [2]))
        let part3 = IOData.byteBuffer(ByteBuffer(bytes: [3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))
        XCTAssertEqual(state.requestStreamPartReceived(part1, promise: nil), .sendBodyPart(part1, nil))

        // oh the channel reports... we should slow down producing...
        XCTAssertEqual(state.writabilityChanged(writable: false), .pauseRequestBodyStream)

        // but we issued a .produceMoreRequestBodyData before... Thus, we must accept more produced
        // data
        XCTAssertEqual(state.requestStreamPartReceived(part2, promise: nil), .sendBodyPart(part2, nil))
        // however when we have put the data on the channel, we should not issue further
        // .produceMoreRequestBodyData events

        // once we receive a writable event again, we can allow the producer to produce more data
        XCTAssertEqual(state.writabilityChanged(writable: true), .resumeRequestBodyStream)
        XCTAssertEqual(state.requestStreamPartReceived(part3, promise: nil), .sendBodyPart(part3, nil))
        XCTAssertEqual(state.requestStreamFinished(promise: nil), .sendRequestEnd(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody]), nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
    }

    func testPOSTContentLengthIsTooLong() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        let part1 = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))

        state.requestStreamPartReceived(part1, promise: nil).assertFailRequest(HTTPClientError.bodyLengthMismatch, .close)

        // if another error happens the new one is ignored
        XCTAssertEqual(state.errorHappened(HTTPClientError.remoteConnectionClosed), .wait(nil))
    }

    func testPOSTContentLengthIsTooShort() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "8")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(8))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))

        state.requestStreamFinished(promise: nil).assertFailRequest(HTTPClientError.bodyLengthMismatch, .close)
    }

    func testRequestBodyStreamIsCancelledIfServerRespondsWith301() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part, promise: nil), .sendBodyPart(part, nil))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .movedPermanently)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: true))
        XCTAssertEqual(state.writabilityChanged(writable: false), .wait(nil))
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait(nil))
        XCTAssertEqual(state.requestStreamPartReceived(part, promise: nil), .wait(nil),
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init(), nil))

        XCTAssertEqual(state.requestStreamPartReceived(part, promise: nil), .wait(nil),
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.requestStreamFinished(promise: nil), .wait(nil),
                       "Expected to drop all stream data after having received a response head, with status >= 300")
    }

    func testStreamPartReceived_whenCancelled() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        let part = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))

        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.cancelled, .none, nil))
        XCTAssertEqual(state.requestStreamPartReceived(part, promise: nil), .wait(nil),
                       "Expected to drop all stream data after having received a response head, with status >= 300")
    }

    func testRequestBodyStreamIsCancelledIfServerRespondsWith301WhileWriteBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part, promise: nil), .sendBodyPart(part, nil))
        XCTAssertEqual(state.writabilityChanged(writable: false), .pauseRequestBodyStream)

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .movedPermanently)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait(nil))
        XCTAssertEqual(state.requestStreamPartReceived(part, promise: nil), .wait(nil),
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init(), nil))

        XCTAssertEqual(state.requestStreamPartReceived(part, promise: nil), .wait(nil),
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.requestStreamFinished(promise: nil), .wait(nil),
                       "Expected to drop all stream data after having received a response head, with status >= 300")
    }

    func testRequestBodyStreamIsContinuedIfServerRespondsWith200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .forwardResponseBodyParts(.init()))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1, promise: nil), .sendBodyPart(part1, nil))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: 8...11))
        XCTAssertEqual(state.requestStreamPartReceived(part2, promise: nil), .sendBodyPart(part2, nil))
        XCTAssertEqual(state.requestStreamFinished(promise: nil), .succeedRequest(.sendRequestEnd, .init(), nil))

        XCTAssertEqual(state.requestStreamPartReceived(part2, promise: nil), .wait(nil))
    }

    func testRequestBodyStreamIsContinuedIfServerSendHeadWithStatus200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1, promise: nil), .sendBodyPart(part1, nil))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: 8...11))
        XCTAssertEqual(state.requestStreamPartReceived(part2, promise: nil), .sendBodyPart(part2, nil))
        XCTAssertEqual(state.requestStreamFinished(promise: nil), .sendRequestEnd(nil))

        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init(), nil))
    }

    func testRequestIsFailedIfRequestBodySizeIsWrongEvenAfterServerRespondedWith200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .forwardResponseBodyParts(.init()))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1, promise: nil), .sendBodyPart(part1, nil))
        state.requestStreamFinished(promise: nil).assertFailRequest(HTTPClientError.bodyLengthMismatch, .close)
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testRequestIsFailedIfRequestBodySizeIsWrongEvenAfterServerSendHeadWithStatus200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1, promise: nil), .sendBodyPart(part1, nil))
        state.requestStreamFinished(promise: nil).assertFailRequest(HTTPClientError.bodyLengthMismatch, .close)
        XCTAssertEqual(state.channelRead(.end(nil)), .wait(nil))
    }

    func testRequestIsNotSendUntilChannelIsWritable() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.writabilityChanged(writable: true), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody]), nil))
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testConnectionBecomesInactiveWhileWaitingForWritable() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait(nil))
        state.channelInactive().assertFailRequest(HTTPClientError.remoteConnectionClosed, .none)
    }

    func testResponseReadingWithBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait(nil))
        XCTAssertEqual(state.channelRead(.body(part1)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part0, part1])))
        XCTAssertEqual(state.read(), .wait(nil))
        XCTAssertEqual(state.read(), .wait(nil), "Expected to be able to consume a second read event")
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .read)
        XCTAssertEqual(state.channelRead(.body(part2)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part2])))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init(), nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
    }

    func testChannelReadCompleteTriggersButNoBodyDataWasReceivedSoFar() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait(nil))
        XCTAssertEqual(state.channelRead(.body(part1)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part0, part1])))
        XCTAssertEqual(state.read(), .wait(nil))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(part2)), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([part2]), nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
    }

    func testResponseReadingWithBackpressureEndOfResponseAllowsReadEventsToTriggerDirectly() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part0])))
        XCTAssertEqual(state.read(), .wait(nil))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .read)
        XCTAssertEqual(state.channelRead(.body(part1)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part1])))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil), "Calling forward more bytes twice is okay")
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(part2)), .wait(nil))
        XCTAssertEqual(state.read(), .read, "Calling `read` while we wait for a channelReadComplete doesn't crash")
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil), "Calling `demandMoreResponseBodyParts` while we wait for a channelReadComplete doesn't crash")
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part2])))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init(), nil))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
    }

    func testCancellingARequestInStateInitializedKeepsTheConnectionAlive() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        state.requestCancelled().assertFailRequest(HTTPClientError.cancelled, .none)
    }

    func testCancellingARequestBeforeBeingSendKeepsTheConnectionAlive() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait(nil))
        state.requestCancelled().assertFailRequest(HTTPClientError.cancelled, .none)
    }

    func testConnectionBecomesWritableBeforeFirstRequest() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait(nil))

        // --- sending request
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        // --- receiving response
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["content-length": "4"])
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody]), nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
    }

    func testCancellingARequestThatIsSent() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))
        state.requestCancelled().assertFailRequest(HTTPClientError.cancelled, .close)
    }

    func testRemoteSuddenlyClosesTheConnection() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: .init([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        state.requestCancelled().assertFailRequest(HTTPClientError.cancelled, .close)
        XCTAssertEqual(state.requestStreamPartReceived(.byteBuffer(.init(bytes: 1...3)), promise: nil), .wait(nil))
    }

    func testReadTimeoutLeadsToFailureWithEverythingAfterBeingIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait(nil))
        state.idleReadTimeoutTriggered().assertFailRequest(HTTPClientError.readTimeout, .close)
        XCTAssertEqual(state.channelRead(.body(ByteBuffer(bytes: 4...7))), .wait(nil))
        XCTAssertEqual(state.channelRead(.body(ByteBuffer(bytes: 8...11))), .wait(nil))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .wait(nil))
    }

    func testResponseWithStatus1XXAreIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let continueHead = HTTPResponseHead(version: .http1_1, status: .continue)
        XCTAssertEqual(state.channelRead(.head(continueHead)), .wait(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init(), nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
    }

    func testReadTimeoutThatFiresToLateIsIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init(), nil))
        XCTAssertEqual(state.idleReadTimeoutTriggered(), .wait(nil), "A read timeout that fires to late must be ignored")
    }

    func testCancellationThatIsInvokedToLateIsIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init(), nil))
        XCTAssertEqual(state.requestCancelled(), .wait(nil), "A cancellation that happens to late is ignored")
    }

    func testErrorWhileRunningARequestClosesTheStream() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        state.errorHappened(HTTPParserError.invalidChunkSize).assertFailRequest(HTTPParserError.invalidChunkSize, .close)
        XCTAssertEqual(state.requestCancelled(), .wait(nil), "A cancellation that happens to late is ignored")
    }

    func testCanReadHTTP1_0ResponseWithoutBody() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_0, status: .internalServerError)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, [], nil))
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testCanReadHTTP1_0ResponseWithBody() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_0, status: .internalServerError)
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, [body], nil))
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testFailHTTP1_0RequestThatIsStillUploading() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .stream)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))

        let part1: ByteBuffer = .init(string: "foo")
        XCTAssertEqual(state.requestStreamPartReceived(.byteBuffer(part1), promise: nil), .sendBodyPart(.byteBuffer(part1), nil))
        let responseHead = HTTPResponseHead(version: .http1_0, status: .ok)
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        state.channelRead(.end(nil)).assertFailRequest(HTTPClientError.remoteConnectionClosed, .close)
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testFailHTTP1RequestWithoutContentLengthWithNIOSSLErrorUncleanShutdown() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        state.errorHappened(NIOSSLError.uncleanShutdown).assertFailRequest(NIOSSLError.uncleanShutdown, .close)
        XCTAssertEqual(state.channelRead(.end(nil)), .wait(nil))
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testNIOSSLErrorUncleanShutdownShouldBeTreatedAsRemoteConnectionCloseWhileInWaitingForHeadState() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        XCTAssertEqual(state.errorHappened(NIOSSLError.uncleanShutdown), .wait(nil))
        state.channelInactive().assertFailRequest(HTTPClientError.remoteConnectionClosed, .none)
    }

    func testArbitraryErrorShouldBeTreatedAsARequestFailureWhileInWaitingForHeadState() {
        struct ArbitraryError: Error, Equatable {}
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        state.errorHappened(ArbitraryError()).assertFailRequest(ArbitraryError(), .close)
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testFailHTTP1RequestWithContentLengthWithNIOSSLErrorUncleanShutdownButIgnoreIt() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["content-length": "30"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))
        XCTAssertEqual(state.errorHappened(NIOSSLError.uncleanShutdown), .wait(nil))
        state.errorHappened(HTTPParserError.invalidEOFState).assertFailRequest(HTTPParserError.invalidEOFState, .close)
        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForDemand() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "50"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))
        XCTAssertEqual(state.read(), .wait(nil))

        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: " baz lightyear"))), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        state.channelInactive().assertFailRequest(HTTPClientError.remoteConnectionClosed, .none)
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForRead() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "50"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))

        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: " baz lightyear"))), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        state.channelInactive().assertFailRequest(HTTPClientError.remoteConnectionClosed, .none)
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForReadAndDemand() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "50"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))

        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: " baz lightyear"))), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        state.channelInactive().assertFailRequest(HTTPClientError.remoteConnectionClosed, .none)
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForReadAndDemandMultipleTimes() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "50"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))

        let part1 = ByteBuffer(string: "baz lightyear")
        XCTAssertEqual(state.channelRead(.body(part1)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))

        let part2 = ByteBuffer(string: "nearly last")
        XCTAssertEqual(state.channelRead(.body(part2)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))

        let part3 = ByteBuffer(string: "final message")
        XCTAssertEqual(state.channelRead(.body(part3)), .wait(nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))

        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, [part1, part2, part3], nil))
        XCTAssertEqual(state.channelReadComplete(), .wait(nil))

        XCTAssertEqual(state.channelInactive(), .wait(nil))
    }
}

extension HTTPRequestStateMachine.Action: Equatable {
    public static func == (lhs: HTTPRequestStateMachine.Action, rhs: HTTPRequestStateMachine.Action) -> Bool {
        switch (lhs, rhs) {
        case (.sendRequestHead(let lhsHead, let lhsStartBody), .sendRequestHead(let rhsHead, let rhsStartBody)):
            return lhsHead == rhsHead && lhsStartBody == rhsStartBody

        case (.sendBodyPart(let lhsData, _), .sendBodyPart(let rhsData, _)):
            return lhsData == rhsData

        case (.sendRequestEnd, .sendRequestEnd):
            return true

        case (.pauseRequestBodyStream, .pauseRequestBodyStream):
            return true
        case (.resumeRequestBodyStream, .resumeRequestBodyStream):
            return true

        case (.forwardResponseHead(let lhsHead, let lhsPauseRequestBodyStream), .forwardResponseHead(let rhsHead, let rhsPauseRequestBodyStream)):
            return lhsHead == rhsHead && lhsPauseRequestBodyStream == rhsPauseRequestBodyStream

        case (.forwardResponseBodyParts(let lhsData), .forwardResponseBodyParts(let rhsData)):
            return lhsData == rhsData

        case (.succeedRequest(let lhsFinalAction, let lhsFinalBuffer, _), .succeedRequest(let rhsFinalAction, let rhsFinalBuffer, _)):
            return lhsFinalAction == rhsFinalAction && lhsFinalBuffer == rhsFinalBuffer

        case (.failRequest(_, let lhsFinalAction, _), .failRequest(_, let rhsFinalAction, _)):
            return lhsFinalAction == rhsFinalAction

        case (.read, .read):
            return true

        case (.wait, .wait):
            return true

        default:
            return false
        }
    }
}

extension HTTPRequestStateMachine.Action {
    fileprivate func assertFailRequest<Error>(
        _ expectedError: Error,
        _ expectedFinalStreamAction: HTTPRequestStateMachine.Action.FinalStreamAction,
        file: StaticString = #file,
        line: UInt = #line
    ) where Error: Swift.Error & Equatable {
        guard case .failRequest(let actualError, let actualFinalStreamAction, _) = self else {
            return XCTFail("expected .failRequest(\(expectedError), \(expectedFinalStreamAction)) but got \(self)", file: file, line: line)
        }
        if let actualError = actualError as? Error {
            XCTAssertEqual(actualError, expectedError, file: file, line: line)
        } else {
            XCTFail("\(actualError) is not equal to \(expectedError)", file: file, line: line)
        }
        XCTAssertEqual(actualFinalStreamAction, expectedFinalStreamAction, file: file, line: line)
    }
}
