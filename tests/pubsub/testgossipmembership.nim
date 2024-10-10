# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[options, deques, sequtils, enumerate, algorithm, sets]
import stew/byteutils
import ../../libp2p/builders
import ../../libp2p/errors
import ../../libp2p/crypto/crypto
import ../../libp2p/stream/bufferstream
import ../../libp2p/protocols/pubsub/[pubsub, gossipsub, mcache, mcache, peertable]
import ../../libp2p/protocols/pubsub/rpc/[message, messages]
import ../../libp2p/switch
import ../../libp2p/muxers/muxer
import ../../libp2p/protocols/pubsub/rpc/protobuf
import utils
import chronos

import ../helpers

proc noop(data: seq[byte]) {.async: (raises: [CancelledError, LPStreamError]).} =
  discard

const MsgIdSuccess = "msg id gen success"

suite "GossipSub Topic Membership Tests":
  teardown:
    checkTrackers()

  # Addition of Designed Test cases for 6. Topic Membership Tests: https://www.notion.so/Gossipsub-651e02d4d7894bb2ac1e4edb55f3192d

  # Generalized setup function to initialize one or more topics
  proc setupGossipSub(
      topics: seq[string], numPeers: int
  ): (TestGossipSub, seq[Connection]) =
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    var conns = newSeq[Connection]()

    for topic in topics:
      gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
      gossipSub.topicParams[topic] = TopicParams.init()
      gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()

      for i in 0 ..< numPeers:
        let conn = TestBufferStream.new(noop)
        conns &= conn
        let peerId = randomPeerId()
        conn.peerId = peerId
        let peer = gossipSub.getPubSubPeer(peerId)
        peer.sendConn = conn
        gossipSub.gossipsub[topic].incl(peer)

    return (gossipSub, conns)

  # Wrapper function to initialize a single topic by converting it into a seq
  proc setupGossipSub(topic: string, numPeers: int): (TestGossipSub, seq[Connection]) =
    setupGossipSub(@[topic], numPeers)

  # Helper function to subscribe to topics
  proc subscribeToTopics(gossipSub: TestGossipSub, topics: seq[string]) =
    for topic in topics:
      gossipSub.subscribe(
        topic,
        proc(topic: string, data: seq[byte]): Future[void] {.async.} =
          discard
        ,
      )

  # Helper function to unsubscribe to topics
  proc unsubscribeFromTopics(gossipSub: TestGossipSub, topics: seq[string]) =
    for topic in topics:
      gossipSub.unsubscribeAll(topic)

  # Simulate the `SUBSCRIBE` to the topic and check proper handling in the mesh and gossipsub structures
  asyncTest "handle SUBSCRIBE to the topic":
    let topic = "test-topic"
    let (gossipSub, conns) = setupGossipSub(topic, 5)

    # Subscribe to the topic
    subscribeToTopics(gossipSub, @[topic])

    # Check if the topic is present in the list of subscribed topics
    check gossipSub.topics.contains(topic)

    # Check if the topic is added to gossipsub and the peers list is not empty
    check gossipSub.gossipsub[topic].len() == 5

    # Close all peer connections and verify that they are properly cleaned up
    await allFuturesThrowing(conns.mapIt(it.close()))

    # Stop the gossipSub switch and wait for it to stop completely
    await gossipSub.switch.stop()

  # Simulate an UNSUBSCRIBE to the topic and check if the topic is removed from the relevant data structures but remains in gossipsub
  asyncTest "handle UNSUBSCRIBE to the topic":
    let topic = "test-topic"
    let (gossipSub, conns) = setupGossipSub(topic, 5)

    # Subscribe to the topic first
    subscribeToTopics(gossipSub, @[topic])

    # Now unsubscribe from the topic
    unsubscribeFromTopics(gossipSub, @[topic])

    # Verify the topic is removed from relevant structures
    check topic notin gossipSub.topics
    check topic notin gossipSub.mesh
    check topic in gossipSub.gossipsub

    # The topic should remain in gossipsub (for fanout)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test subscribing and unsubscribing multiple topics
  asyncTest "handle SUBSCRIBE and UNSUBSCRIBE multiple topics":
    let topics = ["topic1", "topic2", "topic3"].toSeq()
    let (gossipSub, conns) = setupGossipSub(topics, 5)

    # Subscribe to multiple topics
    subscribeToTopics(gossipSub, topics)

    # Verify that all topics are added to the topics and gossipsub
    check gossipSub.topics.len == 3
    for topic in topics:
      check gossipSub.gossipsub[topic].len() == 5

    # Unsubscribe from all topics
    unsubscribeFromTopics(gossipSub, topics)

    # Ensure topics are removed from topics and mesh, but still present in gossipsub
    for topic in topics:
      check topic notin gossipSub.topics
      check topic notin gossipSub.mesh
      check topic in gossipSub.gossipsub

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test ensuring that the number of subscriptions does not exceed the limit set in the GossipSub parameters
  asyncTest "subscription limit test":
    let topicCount = 15 # Total number of topics to be tested
    let gossipSubParams = 10 # Subscription limit for the topics
    let topicNames = toSeq(mapIt(0 .. topicCount - 1, "topic" & $it))

    # Use setupGossipSub to initialize the GossipSub system with connections
    let (gossipSub, conns) = setupGossipSub(topicNames, 0) # No peers for now

    gossipSub.topicsHigh = gossipSubParams # Set the subscription limit

    for topic in topicNames:
      if gossipSub.topics.len < gossipSub.topicsHigh:
        gossipSub.PubSub.subscribe(
          topic,
          proc(topic: string, data: seq[byte]): Future[void] {.async.} =
            discard
          ,
        )
      else:
        # Assert that no subscription happens beyond the limit with custom message
        doAssert gossipSub.topics.len == gossipSub.topicsHigh,
          "Subscription limit exceeded for topic: " & topic

    # Ensure that the number of subscribed topics does not exceed the limit
    doAssert gossipSub.topics.len <= gossipSub.topicsHigh
    doAssert gossipSub.topics.len == gossipSub.topicsHigh

    # Clean up by closing connections and stopping the GossipSub switch
    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()
