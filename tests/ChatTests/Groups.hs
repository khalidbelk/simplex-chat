{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PostfixOperators #-}

module ChatTests.Groups where

import ChatClient
import ChatTests.Utils
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Monad (when)
import qualified Data.Text as T
import Simplex.Chat.Controller (ChatConfig (..))
import Simplex.Chat.Store (agentStoreFile, chatStoreFile)
import Simplex.Chat.Types (GroupMemberRole (..))
import System.Directory (copyFile)
import System.FilePath ((</>))
import Test.Hspec

chatGroupTests :: SpecWith FilePath
chatGroupTests = do
  describe "chat groups" $ do
    describe "add contacts, create group and send/receive messages" testGroup
    it "add contacts, create group and send/receive messages, check messages" testGroupCheckMessages
    it "create and join group with 4 members" testGroup2
    it "create and delete group" testGroupDelete
    it "create group with the same displayName" testGroupSameName
    it "invitee delete group when in status invited" testGroupDeleteWhenInvited
    it "re-add member in status invited" testGroupReAddInvited
    it "re-add member in status invited, change role" testGroupReAddInvitedChangeRole
    it "delete contact before they accept group invitation, contact joins group" testGroupDeleteInvitedContact
    it "member profile is kept when deleting group if other groups have this member" testDeleteGroupMemberProfileKept
    it "remove contact from group and add again" testGroupRemoveAdd
    it "list groups containing group invitations" testGroupList
    it "group message quoted replies" testGroupMessageQuotedReply
    it "group message update" testGroupMessageUpdate
    it "group message edit history" testGroupMessageEditHistory
    it "group message delete" testGroupMessageDelete
    it "group live message" testGroupLiveMessage
    it "update group profile" testUpdateGroupProfile
    it "update member role" testUpdateMemberRole
    it "unused contacts are deleted after all their groups are deleted" testGroupDeleteUnusedContacts
    it "group description is shown as the first message to new members" testGroupDescription
    it "moderate message of another group member" testGroupModerate
    it "moderate message of another group member (full delete)" testGroupModerateFullDelete
    it "moderate message that arrives after the event of moderation" testGroupDelayedModeration
    it "moderate message that arrives after the event of moderation (full delete)" testGroupDelayedModerationFullDelete
  describe "async group connections" $ do
    xit "create and join group when clients go offline" testGroupAsync
  describe "group links" $ do
    it "create group link, join via group link" testGroupLink
    it "delete group, re-join via same link" testGroupLinkDeleteGroupRejoin
    it "sending message to contact created via group link marks it used" testGroupLinkContactUsed
    it "create group link, join via group link - incognito membership" testGroupLinkIncognitoMembership
    it "unused host contact is deleted after all groups with it are deleted" testGroupLinkUnusedHostContactDeleted
    it "leaving groups with unused host contacts deletes incognito profiles" testGroupLinkIncognitoUnusedHostContactsDeleted
    it "group link member role" testGroupLinkMemberRole
    it "leaving and deleting the group joined via link should NOT delete previously existing direct contacts" testGroupLinkLeaveDelete
  describe "group message errors" $ do
    it "show message decryption error" testGroupMsgDecryptError
    it "should report ratchet de-synchronization, synchronize ratchets" testGroupSyncRatchet
    it "synchronize ratchets, reset connection code" testGroupSyncRatchetCodeReset
  describe "message reactions" $ do
    it "set group message reactions" testSetGroupMessageReactions

testGroup :: HasCallStack => SpecWith FilePath
testGroup = versionTestMatrix3 runTestGroup
  where
    runTestGroup alice bob cath = testGroupShared alice bob cath False

testGroupCheckMessages :: HasCallStack => FilePath -> IO ()
testGroupCheckMessages =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> testGroupShared alice bob cath True

testGroupShared :: HasCallStack => TestCC -> TestCC -> TestCC -> Bool -> IO ()
testGroupShared alice bob cath checkMessages = do
  connectUsers alice bob
  connectUsers alice cath
  alice ##> "/g team"
  alice <## "group #team is created"
  alice <## "to add members use /a team <name> or /create link #team"
  alice ##> "/a team bob"
  concurrentlyN_
    [ alice <## "invitation to join the group #team sent to bob",
      do
        bob <## "#team: alice invites you to join the group as admin"
        bob <## "use /j team to accept"
    ]
  bob ##> "/j team"
  concurrently_
    (alice <## "#team: bob joined the group")
    (bob <## "#team: you joined the group")
  when checkMessages $ threadDelay 1000000 -- for deterministic order of messages and "connected" events
  alice ##> "/a team cath"
  concurrentlyN_
    [ alice <## "invitation to join the group #team sent to cath",
      do
        cath <## "#team: alice invites you to join the group as admin"
        cath <## "use /j team to accept"
    ]
  cath ##> "/j team"
  concurrentlyN_
    [ alice <## "#team: cath joined the group",
      do
        cath <## "#team: you joined the group"
        cath <## "#team: member bob (Bob) is connected",
      do
        bob <## "#team: alice added cath (Catherine) to the group (connecting...)"
        bob <## "#team: new member cath is connected"
    ]
  when checkMessages $ threadDelay 1000000 -- for deterministic order of messages and "connected" events
  alice #> "#team hello"
  msgItem1 <- lastItemId alice
  concurrently_
    (bob <# "#team alice> hello")
    (cath <# "#team alice> hello")
  when checkMessages $ threadDelay 1000000 -- server assigns timestamps with one second precision
  bob #> "#team hi there"
  concurrently_
    (alice <# "#team bob> hi there")
    (cath <# "#team bob> hi there")
  when checkMessages $ threadDelay 1000000
  cath #> "#team hey team"
  concurrently_
    (alice <# "#team cath> hey team")
    (bob <# "#team cath> hey team")
  msgItem2 <- lastItemId alice
  bob <##> cath
  when checkMessages $ getReadChats msgItem1 msgItem2
  -- list groups
  alice ##> "/gs"
  alice <## "#team"
  -- list group members
  alice ##> "/ms team"
  alice
    <### [ "alice (Alice): owner, you, created group",
           "bob (Bob): admin, invited, connected",
           "cath (Catherine): admin, invited, connected"
         ]
  -- list contacts
  alice ##> "/contacts"
  alice <## "bob (Bob)"
  alice <## "cath (Catherine)"
  -- test observer role
  alice ##> "/mr team bob observer"
  concurrentlyN_
    [ alice <## "#team: you changed the role of bob from admin to observer",
      bob <## "#team: alice changed your role from admin to observer",
      cath <## "#team: alice changed the role of bob from admin to observer"
    ]
  bob ##> "#team hello"
  bob <## "#team: you don't have permission to send messages"
  bob ##> "/rm team cath"
  bob <## "#team: you have insufficient permissions for this action, the required role is admin"
  cath #> "#team hello"
  concurrentlyN_
    [ alice <# "#team cath> hello",
      bob <# "#team cath> hello"
    ]
  alice ##> "/mr team bob admin"
  concurrentlyN_
    [ alice <## "#team: you changed the role of bob from observer to admin",
      bob <## "#team: alice changed your role from observer to admin",
      cath <## "#team: alice changed the role of bob from observer to admin"
    ]
  -- remove member
  bob ##> "/rm team cath"
  concurrentlyN_
    [ bob <## "#team: you removed cath from the group",
      alice <## "#team: bob removed cath from the group",
      do
        cath <## "#team: bob removed you from the group"
        cath <## "use /d #team to delete the group"
    ]
  bob #> "#team hi"
  concurrently_
    (alice <# "#team bob> hi")
    (cath </)
  alice #> "#team hello"
  concurrently_
    (bob <# "#team alice> hello")
    (cath </)
  cath ##> "#team hello"
  cath <## "you are no longer a member of the group"
  bob <##> cath
  -- delete contact
  alice ##> "/d bob"
  alice <## "bob: contact is deleted"
  alice ##> "@bob hey"
  alice <## "no contact bob"
  when checkMessages $ threadDelay 1000000
  alice #> "#team checking connection"
  bob <# "#team alice> checking connection"
  when checkMessages $ threadDelay 1000000
  bob #> "#team received"
  alice <# "#team bob> received"
  when checkMessages $ do
    alice @@@ [("@cath", "sent invitation to join group team as admin"), ("#team", "received")]
    bob @@@ [("@alice", "received invitation to join group team as admin"), ("@cath", "hey"), ("#team", "received")]
  -- test clearing chat
  alice #$> ("/clear #team", id, "#team: all messages are removed locally ONLY")
  alice #$> ("/_get chat #1 count=100", chat, [])
  bob #$> ("/clear #team", id, "#team: all messages are removed locally ONLY")
  bob #$> ("/_get chat #1 count=100", chat, [])
  cath #$> ("/clear #team", id, "#team: all messages are removed locally ONLY")
  cath #$> ("/_get chat #1 count=100", chat, [])
  where
    getReadChats :: HasCallStack => String -> String -> IO ()
    getReadChats msgItem1 msgItem2 = do
      alice @@@ [("#team", "hey team"), ("@cath", "sent invitation to join group team as admin"), ("@bob", "sent invitation to join group team as admin")]
      alice #$> ("/_get chat #1 count=100", chat, [(0, "connected"), (0, "connected"), (1, "hello"), (0, "hi there"), (0, "hey team")])
      -- "before" and "after" define a chat item id across all chats,
      -- so we take into account group event items as well as sent group invitations in direct chats
      alice #$> ("/_get chat #1 after=" <> msgItem1 <> " count=100", chat, [(0, "hi there"), (0, "hey team")])
      alice #$> ("/_get chat #1 before=" <> msgItem2 <> " count=100", chat, [(0, "connected"), (0, "connected"), (1, "hello"), (0, "hi there")])
      alice #$> ("/_get chat #1 count=100 search=team", chat, [(0, "hey team")])
      bob @@@ [("@cath", "hey"), ("#team", "hey team"), ("@alice", "received invitation to join group team as admin")]
      bob #$> ("/_get chat #1 count=100", chat, groupFeatures <> [(0, "connected"), (0, "added cath (Catherine)"), (0, "connected"), (0, "hello"), (1, "hi there"), (0, "hey team")])
      cath @@@ [("@bob", "hey"), ("#team", "hey team"), ("@alice", "received invitation to join group team as admin")]
      cath #$> ("/_get chat #1 count=100", chat, groupFeatures <> [(0, "connected"), (0, "connected"), (0, "hello"), (0, "hi there"), (1, "hey team")])
      alice #$> ("/_read chat #1 from=1 to=100", id, "ok")
      bob #$> ("/_read chat #1 from=1 to=100", id, "ok")
      cath #$> ("/_read chat #1 from=1 to=100", id, "ok")
      alice #$> ("/_read chat #1", id, "ok")
      bob #$> ("/_read chat #1", id, "ok")
      cath #$> ("/_read chat #1", id, "ok")
      alice #$> ("/_unread chat #1 on", id, "ok")
      alice #$> ("/_unread chat #1 off", id, "ok")

testGroup2 :: HasCallStack => FilePath -> IO ()
testGroup2 =
  testChat4 aliceProfile bobProfile cathProfile danProfile $
    \alice bob cath dan -> do
      connectUsers alice bob
      connectUsers alice cath
      connectUsers bob dan
      connectUsers alice dan
      alice ##> "/g club"
      alice <## "group #club is created"
      alice <## "to add members use /a club <name> or /create link #club"
      alice ##> "/a club bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #club sent to bob",
          do
            bob <## "#club: alice invites you to join the group as admin"
            bob <## "use /j club to accept"
        ]
      alice ##> "/a club cath"
      concurrentlyN_
        [ alice <## "invitation to join the group #club sent to cath",
          do
            cath <## "#club: alice invites you to join the group as admin"
            cath <## "use /j club to accept"
        ]
      bob ##> "/j club"
      concurrently_
        (alice <## "#club: bob joined the group")
        (bob <## "#club: you joined the group")
      cath ##> "/j club"
      concurrentlyN_
        [ alice <## "#club: cath joined the group",
          do
            cath <## "#club: you joined the group"
            cath <## "#club: member bob (Bob) is connected",
          do
            bob <## "#club: alice added cath (Catherine) to the group (connecting...)"
            bob <## "#club: new member cath is connected"
        ]
      bob ##> "/a club dan"
      concurrentlyN_
        [ bob <## "invitation to join the group #club sent to dan",
          do
            dan <## "#club: bob invites you to join the group as admin"
            dan <## "use /j club to accept"
        ]
      dan ##> "/j club"
      concurrentlyN_
        [ bob <## "#club: dan joined the group",
          do
            dan <## "#club: you joined the group"
            dan
              <### [ "#club: member alice_1 (Alice) is connected",
                     "contact alice_1 is merged into alice",
                     "use @alice <message> to send messages",
                     "#club: member cath (Catherine) is connected"
                   ],
          do
            alice <## "#club: bob added dan_1 (Daniel) to the group (connecting...)"
            alice <## "#club: new member dan_1 is connected"
            alice <## "contact dan_1 is merged into dan"
            alice <## "use @dan <message> to send messages",
          do
            cath <## "#club: bob added dan (Daniel) to the group (connecting...)"
            cath <## "#club: new member dan is connected"
        ]
      alice #> "#club hello"
      concurrentlyN_
        [ bob <# "#club alice> hello",
          cath <# "#club alice> hello",
          dan <# "#club alice> hello"
        ]
      bob #> "#club hi there"
      concurrentlyN_
        [ alice <# "#club bob> hi there",
          cath <# "#club bob> hi there",
          dan <# "#club bob> hi there"
        ]
      cath #> "#club hey"
      concurrentlyN_
        [ alice <# "#club cath> hey",
          bob <# "#club cath> hey",
          dan <# "#club cath> hey"
        ]
      dan #> "#club how is it going?"
      concurrentlyN_
        [ alice <# "#club dan> how is it going?",
          bob <# "#club dan> how is it going?",
          cath <# "#club dan> how is it going?"
        ]
      bob <##> cath
      dan <##> cath
      dan <##> alice
      -- show last messages
      alice ##> "/t #club 8"
      alice -- these strings are expected in any order because of sorting by time and rounding of time for sent
        <##? [ "#club bob> connected",
               "#club cath> connected",
               "#club bob> added dan (Daniel)",
               "#club dan> connected",
               "#club hello",
               "#club bob> hi there",
               "#club cath> hey",
               "#club dan> how is it going?"
             ]
      alice ##> "/t @dan 2"
      alice
        <##? [ "dan> hi",
               "@dan hey"
             ]
      -- TODO this fails returning only 23 lines out of 24
      -- alice ##> "/t 24"
      -- alice
      --   <##? [ "@bob sent invitation to join group club as admin",
      --          "@cath sent invitation to join group club as admin",
      --          "#club bob> connected",
      --          "#club cath> connected",
      --          "#club bob> added dan (Daniel)", -- either this is missing
      --          "#club dan> connected",
      --          "#club hello",
      --          "#club bob> hi there",
      --          "#club cath> hey",
      --          "#club dan> how is it going?",
      --          "dan> hi",
      --          "@dan hey",
      --          "dan> Disappearing messages: off",
      --          "dan> Full deletion: off",
      --          "dan> Voice messages: enabled",
      --          "dan> Audio/video calls: enabled",
      --          "bob> Disappearing messages: off", -- or this one
      --          "bob> Full deletion: off",
      --          "bob> Voice messages: enabled",
      --          "bob> Audio/video calls: enabled",
      --          "cath> Disappearing messages: off",
      --          "cath> Full deletion: off",
      --          "cath> Voice messages: enabled",
      --          "cath> Audio/video calls: enabled"
      --        ]
      -- remove member
      cath ##> "/rm club dan"
      concurrentlyN_
        [ cath <## "#club: you removed dan from the group",
          alice <## "#club: cath removed dan from the group",
          bob <## "#club: cath removed dan from the group",
          do
            dan <## "#club: cath removed you from the group"
            dan <## "use /d #club to delete the group"
        ]
      alice #> "#club hello"
      concurrentlyN_
        [ bob <# "#club alice> hello",
          cath <# "#club alice> hello",
          (dan </)
        ]
      bob #> "#club hi there"
      concurrentlyN_
        [ alice <# "#club bob> hi there",
          cath <# "#club bob> hi there",
          (dan </)
        ]
      cath #> "#club hey"
      concurrentlyN_
        [ alice <# "#club cath> hey",
          bob <# "#club cath> hey",
          (dan </)
        ]
      dan ##> "#club how is it going?"
      dan <## "you are no longer a member of the group"
      dan ##> "/d #club"
      dan <## "#club: you deleted the group"
      dan <##> cath
      dan <##> alice
      -- member leaves
      bob ##> "/l club"
      concurrentlyN_
        [ do
            bob <## "#club: you left the group"
            bob <## "use /d #club to delete the group",
          alice <## "#club: bob left the group",
          cath <## "#club: bob left the group"
        ]
      alice #> "#club hello"
      concurrently_
        (cath <# "#club alice> hello")
        (bob </)
      cath #> "#club hey"
      concurrently_
        (alice <# "#club cath> hey")
        (bob </)
      bob ##> "#club how is it going?"
      bob <## "you are no longer a member of the group"
      bob ##> "/d #club"
      bob <## "#club: you deleted the group"
      bob <##> cath
      bob <##> alice

testGroupDelete :: HasCallStack => FilePath -> IO ()
testGroupDelete =
  testChatCfg3 cfg aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      alice ##> "/d #team"
      concurrentlyN_
        [ alice <## "#team: you deleted the group",
          do
            bob <## "#team: alice deleted the group"
            bob <## "use /d #team to delete the local copy of the group",
          do
            cath <## "#team: alice deleted the group"
            cath <## "use /d #team to delete the local copy of the group"
        ]
      alice ##> "#team hi"
      alice <## "no group #team"
      bob ##> "/d #team"
      bob <## "#team: you deleted the group"
      cath ##> "#team hi"
      cath <## "you are no longer a member of the group"
      cath ##> "/d #team"
      cath <## "#team: you deleted the group"
      alice <##> bob
      alice <##> cath
      -- unused group contacts are deleted
      threadDelay 3000000
      bob ##> "@cath hi"
      bob <## "no contact cath"
      (cath </)
      cath ##> "@bob hi"
      cath <## "no contact bob"
      (bob </)
  where
    cfg = testCfg {initialCleanupManagerDelay = 0, cleanupManagerInterval = 1, cleanupManagerStepDelay = 0}

testGroupSameName :: HasCallStack => FilePath -> IO ()
testGroupSameName =
  testChat2 aliceProfile bobProfile $
    \alice _ -> do
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/g team"
      alice <## "group #team_1 is created"
      alice <## "to add members use /a team_1 <name> or /create link #team_1"

testGroupDeleteWhenInvited :: HasCallStack => FilePath -> IO ()
testGroupDeleteWhenInvited =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      connectUsers alice bob
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]
      bob ##> "/d #team"
      bob <## "#team: you deleted the group"
      -- alice doesn't receive notification that bob deleted group,
      -- but she can re-add bob
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]

testGroupReAddInvited :: HasCallStack => FilePath -> IO ()
testGroupReAddInvited =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      connectUsers alice bob
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]
      -- alice re-adds bob, he sees it as the same group
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]
      -- if alice removes bob and then re-adds him, she uses a new connection request
      -- and he sees it as a new group with a different local display name
      alice ##> "/rm team bob"
      alice <## "#team: you removed bob from the group"
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team_1: alice invites you to join the group as admin"
            bob <## "use /j team_1 to accept"
        ]

testGroupReAddInvitedChangeRole :: HasCallStack => FilePath -> IO ()
testGroupReAddInvitedChangeRole =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      connectUsers alice bob
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]
      -- alice re-adds bob, he sees it as the same group
      alice ##> "/a team bob owner"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as owner"
            bob <## "use /j team to accept"
        ]
      -- bob joins as owner
      bob ##> "/j team"
      concurrently_
        (alice <## "#team: bob joined the group")
        (bob <## "#team: you joined the group")
      bob ##> "/d #team"
      concurrentlyN_
        [ bob <## "#team: you deleted the group",
          do
            alice <## "#team: bob deleted the group"
            alice <## "use /d #team to delete the local copy of the group"
        ]
      bob ##> "#team hi"
      bob <## "no group #team"
      alice ##> "/d #team"
      alice <## "#team: you deleted the group"

testGroupDeleteInvitedContact :: HasCallStack => FilePath -> IO ()
testGroupDeleteInvitedContact =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      connectUsers alice bob
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]
      threadDelay 500000
      alice ##> "/d bob"
      alice <## "bob: contact is deleted"
      bob ##> "/j team"
      concurrently_
        (alice <## "#team: bob joined the group")
        (bob <## "#team: you joined the group")
      alice #> "#team hello"
      bob <# "#team alice> hello"
      bob #> "#team hi there"
      alice <# "#team bob> hi there"
      alice ##> "@bob hey"
      alice <## "no contact bob"
      bob #> "@alice hey"
      bob <## "[alice, contactId: 2, connId: 1] error: connection authorization failed - this could happen if connection was deleted, secured with different credentials, or due to a bug - please re-create the connection"
      (alice </)

testDeleteGroupMemberProfileKept :: HasCallStack => FilePath -> IO ()
testDeleteGroupMemberProfileKept =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      connectUsers alice bob
      -- group 1
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]
      bob ##> "/j team"
      concurrently_
        (alice <## "#team: bob joined the group")
        (bob <## "#team: you joined the group")
      alice #> "#team hello"
      bob <# "#team alice> hello"
      bob #> "#team hi there"
      alice <# "#team bob> hi there"
      -- group 2
      alice ##> "/g club"
      alice <## "group #club is created"
      alice <## "to add members use /a club <name> or /create link #club"
      alice ##> "/a club bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #club sent to bob",
          do
            bob <## "#club: alice invites you to join the group as admin"
            bob <## "use /j club to accept"
        ]
      bob ##> "/j club"
      concurrently_
        (alice <## "#club: bob joined the group")
        (bob <## "#club: you joined the group")
      alice #> "#club hello"
      bob <# "#club alice> hello"
      bob #> "#club hi there"
      alice <# "#club bob> hi there"
      -- delete contact
      alice ##> "/d bob"
      alice <## "bob: contact is deleted"
      alice ##> "@bob hey"
      alice <## "no contact bob"
      bob #> "@alice hey"
      bob <## "[alice, contactId: 2, connId: 1] error: connection authorization failed - this could happen if connection was deleted, secured with different credentials, or due to a bug - please re-create the connection"
      (alice </)
      -- delete group 1
      alice ##> "/d #team"
      concurrentlyN_
        [ alice <## "#team: you deleted the group",
          do
            bob <## "#team: alice deleted the group"
            bob <## "use /d #team to delete the local copy of the group"
        ]
      alice ##> "#team hi"
      alice <## "no group #team"
      bob ##> "/d #team"
      bob <## "#team: you deleted the group"
      -- group 2 still works
      alice #> "#club checking connection"
      bob <# "#club alice> checking connection"
      bob #> "#club received"
      alice <# "#club bob> received"

testGroupRemoveAdd :: HasCallStack => FilePath -> IO ()
testGroupRemoveAdd =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      -- remove member
      alice ##> "/rm team bob"
      concurrentlyN_
        [ alice <## "#team: you removed bob from the group",
          do
            bob <## "#team: alice removed you from the group"
            bob <## "use /d #team to delete the group",
          cath <## "#team: alice removed bob from the group"
        ]
      alice ##> "/a team bob"
      alice <## "invitation to join the group #team sent to bob"
      bob <## "#team_1: alice invites you to join the group as admin"
      bob <## "use /j team_1 to accept"
      bob ##> "/j team_1"
      concurrentlyN_
        [ alice <## "#team: bob joined the group",
          do
            bob <## "#team_1: you joined the group"
            bob <## "#team_1: member cath_1 (Catherine) is connected"
            bob <## "contact cath_1 is merged into cath"
            bob <## "use @cath <message> to send messages",
          do
            cath <## "#team: alice added bob_1 (Bob) to the group (connecting...)"
            cath <## "#team: new member bob_1 is connected"
            cath <## "contact bob_1 is merged into bob"
            cath <## "use @bob <message> to send messages"
        ]
      alice #> "#team hi"
      concurrently_
        (bob <# "#team_1 alice> hi")
        (cath <# "#team alice> hi")
      bob #> "#team_1 hey"
      concurrently_
        (alice <# "#team bob> hey")
        (cath <# "#team bob> hey")
      cath #> "#team hello"
      concurrently_
        (alice <# "#team cath> hello")
        (bob <# "#team_1 cath> hello")

testGroupList :: HasCallStack => FilePath -> IO ()
testGroupList =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      createGroup2 "team" alice bob
      alice ##> "/g tennis"
      alice <## "group #tennis is created"
      alice <## "to add members use /a tennis <name> or /create link #tennis"
      alice ##> "/a tennis bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #tennis sent to bob",
          do
            bob <## "#tennis: alice invites you to join the group as admin"
            bob <## "use /j tennis to accept"
        ]
      -- alice sees both groups
      alice ##> "/gs"
      alice <### ["#team", "#tennis"]
      -- bob sees #tennis as invitation
      bob ##> "/gs"
      bob
        <### [ "#team",
               "#tennis - you are invited (/j tennis to join, /d #tennis to delete invitation)"
             ]
      -- after deleting invitation bob sees only one group
      bob ##> "/d #tennis"
      bob <## "#tennis: you deleted the group"
      bob ##> "/gs"
      bob <## "#team"

testGroupMessageQuotedReply :: HasCallStack => FilePath -> IO ()
testGroupMessageQuotedReply =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      threadDelay 1000000
      alice #> "#team hello! how are you?"
      concurrently_
        (bob <# "#team alice> hello! how are you?")
        (cath <# "#team alice> hello! how are you?")
      threadDelay 1000000
      bob `send` "> #team @alice (hello) hello, all good, you?"
      bob <# "#team > alice hello! how are you?"
      bob <## "      hello, all good, you?"
      concurrently_
        ( do
            alice <# "#team bob> > alice hello! how are you?"
            alice <## "      hello, all good, you?"
        )
        ( do
            cath <# "#team bob> > alice hello! how are you?"
            cath <## "      hello, all good, you?"
        )
      bob #$> ("/_get chat #1 count=2", chat', [((0, "hello! how are you?"), Nothing), ((1, "hello, all good, you?"), Just (0, "hello! how are you?"))])
      alice #$> ("/_get chat #1 count=2", chat', [((1, "hello! how are you?"), Nothing), ((0, "hello, all good, you?"), Just (1, "hello! how are you?"))])
      cath #$> ("/_get chat #1 count=2", chat', [((0, "hello! how are you?"), Nothing), ((0, "hello, all good, you?"), Just (0, "hello! how are you?"))])
      bob `send` "> #team bob (hello, all good) will tell more"
      bob <# "#team > bob hello, all good, you?"
      bob <## "      will tell more"
      concurrently_
        ( do
            alice <# "#team bob> > bob hello, all good, you?"
            alice <## "      will tell more"
        )
        ( do
            cath <# "#team bob> > bob hello, all good, you?"
            cath <## "      will tell more"
        )
      bob #$> ("/_get chat #1 count=1", chat', [((1, "will tell more"), Just (1, "hello, all good, you?"))])
      alice #$> ("/_get chat #1 count=1", chat', [((0, "will tell more"), Just (0, "hello, all good, you?"))])
      cath #$> ("/_get chat #1 count=1", chat', [((0, "will tell more"), Just (0, "hello, all good, you?"))])
      threadDelay 1000000
      cath `send` "> #team bob (hello) hi there!"
      cath <# "#team > bob hello, all good, you?"
      cath <## "      hi there!"
      concurrently_
        ( do
            alice <# "#team cath> > bob hello, all good, you?"
            alice <## "      hi there!"
        )
        ( do
            bob <# "#team cath> > bob hello, all good, you?"
            bob <## "      hi there!"
        )
      cath #$> ("/_get chat #1 count=1", chat', [((1, "hi there!"), Just (0, "hello, all good, you?"))])
      alice #$> ("/_get chat #1 count=1", chat', [((0, "hi there!"), Just (0, "hello, all good, you?"))])
      bob #$> ("/_get chat #1 count=1", chat', [((0, "hi there!"), Just (1, "hello, all good, you?"))])
      alice `send` "> #team (will tell) go on"
      alice <# "#team > bob will tell more"
      alice <## "      go on"
      concurrently_
        ( do
            bob <# "#team alice> > bob will tell more"
            bob <## "      go on"
        )
        ( do
            cath <# "#team alice> > bob will tell more"
            cath <## "      go on"
        )

testGroupMessageUpdate :: HasCallStack => FilePath -> IO ()
testGroupMessageUpdate =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      threadDelay 1000000
      -- alice, bob: msg id 5, cath: msg id 4 (after group invitations & group events)
      alice #> "#team hello!"
      concurrently_
        (bob <# "#team alice> hello!")
        (cath <# "#team alice> hello!")

      msgItemId1 <- lastItemId alice
      alice ##> ("/_update item #1 " <> msgItemId1 <> " text hello!")
      alice <## "message didn't change"

      alice ##> ("/_update item #1 " <> msgItemId1 <> " text hey 👋")
      alice <# "#team [edited] hey 👋"
      concurrently_
        (bob <# "#team alice> [edited] hey 👋")
        (cath <# "#team alice> [edited] hey 👋")

      alice #$> ("/_get chat #1 count=1", chat', [((1, "hey 👋"), Nothing)])
      bob #$> ("/_get chat #1 count=1", chat', [((0, "hey 👋"), Nothing)])
      cath #$> ("/_get chat #1 count=1", chat', [((0, "hey 👋"), Nothing)])

      threadDelay 1000000
      -- alice, bob: msg id 6, cath: msg id 5
      bob `send` "> #team @alice (hey) hi alice"
      bob <# "#team > alice hey 👋"
      bob <## "      hi alice"
      concurrently_
        ( do
            alice <# "#team bob> > alice hey 👋"
            alice <## "      hi alice"
        )
        ( do
            cath <# "#team bob> > alice hey 👋"
            cath <## "      hi alice"
        )

      alice #$> ("/_get chat #1 count=2", chat', [((1, "hey 👋"), Nothing), ((0, "hi alice"), Just (1, "hey 👋"))])
      bob #$> ("/_get chat #1 count=2", chat', [((0, "hey 👋"), Nothing), ((1, "hi alice"), Just (0, "hey 👋"))])
      cath #$> ("/_get chat #1 count=2", chat', [((0, "hey 👋"), Nothing), ((0, "hi alice"), Just (0, "hey 👋"))])

      alice ##> ("/_update item #1 " <> msgItemId1 <> " text greetings 🤝")
      alice <# "#team [edited] greetings 🤝"
      concurrently_
        (bob <# "#team alice> [edited] greetings 🤝")
        (cath <# "#team alice> [edited] greetings 🤝")

      msgItemId2 <- lastItemId alice
      alice #$> ("/_update item #1 " <> msgItemId2 <> " text updating bob's message", id, "cannot update this item")

      threadDelay 1000000
      cath `send` "> #team @alice (greetings) greetings!"
      cath <# "#team > alice greetings 🤝"
      cath <## "      greetings!"
      concurrently_
        ( do
            alice <# "#team cath> > alice greetings 🤝"
            alice <## "      greetings!"
        )
        ( do
            bob <# "#team cath> > alice greetings 🤝"
            bob <## "      greetings!"
        )

      alice #$> ("/_get chat #1 count=3", chat', [((1, "greetings 🤝"), Nothing), ((0, "hi alice"), Just (1, "hey 👋")), ((0, "greetings!"), Just (1, "greetings 🤝"))])
      bob #$> ("/_get chat #1 count=3", chat', [((0, "greetings 🤝"), Nothing), ((1, "hi alice"), Just (0, "hey 👋")), ((0, "greetings!"), Just (0, "greetings 🤝"))])
      cath #$> ("/_get chat #1 count=3", chat', [((0, "greetings 🤝"), Nothing), ((0, "hi alice"), Just (0, "hey 👋")), ((1, "greetings!"), Just (0, "greetings 🤝"))])

testGroupMessageEditHistory :: HasCallStack => FilePath -> IO ()
testGroupMessageEditHistory =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      createGroup2 "team" alice bob
      threadDelay 1000000
      alice #> "#team hello!"
      bob <# "#team alice> hello!"
      aliceItemId <- lastItemId alice
      bobItemId <- lastItemId bob

      alice ##> ("/_get item info #1 " <> aliceItemId)
      alice <##. "sent at: "
      alice <## "message history:"
      alice .<## ": hello!"
      bob ##> ("/_get item info #1 " <> bobItemId)
      bob <##. "sent at: "
      bob <##. "received at: "
      bob <## "message history:"
      bob .<## ": hello!"

      alice ##> ("/_update item #1 " <> aliceItemId <> " text hey 👋")
      alice <# "#team [edited] hey 👋"
      bob <# "#team alice> [edited] hey 👋"

      alice ##> ("/_get item info #1 " <> aliceItemId)
      alice <##. "sent at: "
      alice <## "message history:"
      alice .<## ": hey 👋"
      alice .<## ": hello!"
      bob ##> ("/_get item info #1 " <> bobItemId)
      bob <##. "sent at: "
      bob <##. "received at: "
      bob <## "message history:"
      bob .<## ": hey 👋"
      bob .<## ": hello!"

      alice ##> ("/_update item #1 " <> aliceItemId <> " text hello there")
      alice <# "#team [edited] hello there"
      bob <# "#team alice> [edited] hello there"

      alice ##> "/item info #team hello"
      alice <##. "sent at: "
      alice <## "message history:"
      alice .<## ": hello there"
      alice .<## ": hey 👋"
      alice .<## ": hello!"
      bob ##> "/item info #team hello"
      bob <##. "sent at: "
      bob <##. "received at: "
      bob <## "message history:"
      bob .<## ": hello there"
      bob .<## ": hey 👋"
      bob .<## ": hello!"

      bob #$> ("/_delete item #1 " <> bobItemId <> " internal", id, "message deleted")

      alice ##> ("/_update item #1 " <> aliceItemId <> " text hey there")
      alice <# "#team [edited] hey there"
      bob <# "#team alice> [edited] hey there"

      alice ##> "/item info #team hey"
      alice <##. "sent at: "
      alice <## "message history:"
      alice .<## ": hey there"
      alice .<## ": hello there"
      alice .<## ": hey 👋"
      alice .<## ": hello!"
      bob ##> "/item info #team hey"
      bob <##. "sent at: "
      bob <##. "received at: "
      bob <## "message history:"
      bob .<## ": hey there"

testGroupMessageDelete :: HasCallStack => FilePath -> IO ()
testGroupMessageDelete =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      threadDelay 1000000
      -- alice, bob: msg id 5, cath: msg id 4 (after group invitations & group events)
      alice #> "#team hello!"
      concurrently_
        (bob <# "#team alice> hello!")
        (cath <# "#team alice> hello!")

      msgItemId1 <- lastItemId alice
      alice #$> ("/_delete item #1 " <> msgItemId1 <> " internal", id, "message deleted")

      alice #$> ("/_get chat #1 count=1", chat, [(0, "connected")])
      bob #$> ("/_get chat #1 count=1", chat, [(0, "hello!")])
      cath #$> ("/_get chat #1 count=1", chat, [(0, "hello!")])

      threadDelay 1000000
      -- alice: msg id 5, bob: msg id 6, cath: msg id 5
      bob `send` "> #team @alice (hello) hi alic"
      bob <# "#team > alice hello!"
      bob <## "      hi alic"
      concurrently_
        ( do
            alice <# "#team bob> > alice hello!"
            alice <## "      hi alic"
        )
        ( do
            cath <# "#team bob> > alice hello!"
            cath <## "      hi alic"
        )

      alice #$> ("/_get chat #1 count=1", chat', [((0, "hi alic"), Just (1, "hello!"))])
      bob #$> ("/_get chat #1 count=2", chat', [((0, "hello!"), Nothing), ((1, "hi alic"), Just (0, "hello!"))])
      cath #$> ("/_get chat #1 count=2", chat', [((0, "hello!"), Nothing), ((0, "hi alic"), Just (0, "hello!"))])

      msgItemId2 <- lastItemId alice
      alice #$> ("/_delete item #1 " <> msgItemId2 <> " internal", id, "message deleted")

      alice #$> ("/_get chat #1 count=1", chat', [((0, "connected"), Nothing)])
      bob #$> ("/_get chat #1 count=2", chat', [((0, "hello!"), Nothing), ((1, "hi alic"), Just (0, "hello!"))])
      cath #$> ("/_get chat #1 count=2", chat', [((0, "hello!"), Nothing), ((0, "hi alic"), Just (0, "hello!"))])

      -- alice: msg id 5
      msgItemId3 <- lastItemId bob
      bob ##> ("/_update item #1 " <> msgItemId3 <> " text hi alice")
      bob <# "#team [edited] > alice hello!"
      bob <## "      hi alice"
      concurrently_
        (alice <# "#team bob> [edited] hi alice")
        ( do
            cath <# "#team bob> [edited] > alice hello!"
            cath <## "      hi alice"
        )

      alice #$> ("/_get chat #1 count=1", chat', [((0, "hi alice"), Nothing)])
      bob #$> ("/_get chat #1 count=2", chat', [((0, "hello!"), Nothing), ((1, "hi alice"), Just (0, "hello!"))])
      cath #$> ("/_get chat #1 count=2", chat', [((0, "hello!"), Nothing), ((0, "hi alice"), Just (0, "hello!"))])

      threadDelay 1000000
      -- alice: msg id 6, bob: msg id 7, cath: msg id 6
      cath #> "#team how are you?"
      concurrently_
        (alice <# "#team cath> how are you?")
        (bob <# "#team cath> how are you?")

      msgItemId4 <- lastItemId cath
      cath #$> ("/_delete item #1 " <> msgItemId4 <> " broadcast", id, "message marked deleted")
      concurrently_
        (alice <# "#team cath> [marked deleted] how are you?")
        (bob <# "#team cath> [marked deleted] how are you?")

      alice ##> "/last_item_id 1"
      msgItemId6 <- getTermLine alice
      alice #$> ("/_delete item #1 " <> msgItemId6 <> " broadcast", id, "cannot delete this item")
      alice #$> ("/_delete item #1 " <> msgItemId6 <> " internal", id, "message deleted")

      alice #$> ("/_get chat #1 count=1", chat', [((0, "how are you? [marked deleted]"), Nothing)])
      bob #$> ("/_get chat #1 count=3", chat', [((0, "hello!"), Nothing), ((1, "hi alice"), Just (0, "hello!")), ((0, "how are you? [marked deleted]"), Nothing)])
      cath #$> ("/_get chat #1 count=3", chat', [((0, "hello!"), Nothing), ((0, "hi alice"), Just (0, "hello!")), ((1, "how are you? [marked deleted]"), Nothing)])

testGroupLiveMessage :: HasCallStack => FilePath -> IO ()
testGroupLiveMessage =
  testChat3 aliceProfile bobProfile cathProfile $ \alice bob cath -> do
    createGroup3 "team" alice bob cath
    threadDelay 500000
    -- non-empty live message is sent instantly
    alice `send` "/live #team hello"
    msgItemId1 <- lastItemId alice
    bob <#. "#team alice> [LIVE started]"
    cath <#. "#team alice> [LIVE started]"
    alice ##> ("/_update item #1 " <> msgItemId1 <> " text hello there")
    alice <# "#team [LIVE] hello there"
    bob <# "#team alice> [LIVE ended] hello there"
    cath <# "#team alice> [LIVE ended] hello there"
    -- empty live message is also sent instantly
    threadDelay 1000000
    alice `send` "/live #team"
    msgItemId2 <- lastItemId alice
    bob <#. "#team alice> [LIVE started]"
    cath <#. "#team alice> [LIVE started]"
    alice ##> ("/_update item #1 " <> msgItemId2 <> " text hello 2")
    alice <# "#team [LIVE] hello 2"
    bob <# "#team alice> [LIVE ended] hello 2"
    cath <# "#team alice> [LIVE ended] hello 2"
    -- live message has edit history
    alice ##> ("/_get item info #1 " <> msgItemId2)
    alice <##. "sent at: "
    alice <## "message history:"
    alice .<## ": hello 2"
    alice .<## ":"
    bobItemId <- lastItemId bob
    bob ##> ("/_get item info #1 " <> bobItemId)
    bob <##. "sent at: "
    bob <##. "received at: "
    bob <## "message history:"
    bob .<## ": hello 2"
    bob .<## ":"

testUpdateGroupProfile :: HasCallStack => FilePath -> IO ()
testUpdateGroupProfile =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      threadDelay 1000000
      alice #> "#team hello!"
      concurrently_
        (bob <# "#team alice> hello!")
        (cath <# "#team alice> hello!")
      bob ##> "/gp team my_team"
      bob <## "#team: you have insufficient permissions for this action, the required role is owner"
      alice ##> "/gp team my_team"
      alice <## "changed to #my_team"
      concurrentlyN_
        [ do
            bob <## "alice updated group #team:"
            bob <## "changed to #my_team",
          do
            cath <## "alice updated group #team:"
            cath <## "changed to #my_team"
        ]
      bob #> "#my_team hi"
      concurrently_
        (alice <# "#my_team bob> hi")
        (cath <# "#my_team bob> hi")

testUpdateMemberRole :: HasCallStack => FilePath -> IO ()
testUpdateMemberRole =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      connectUsers alice bob
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      addMember "team" alice bob GRAdmin
      alice ##> "/mr team bob member"
      alice <## "#team: you changed the role of bob from admin to member"
      bob <## "#team: alice invites you to join the group as member"
      bob <## "use /j team to accept"
      bob ##> "/j team"
      concurrently_
        (alice <## "#team: bob joined the group")
        (bob <## "#team: you joined the group")
      connectUsers bob cath
      bob ##> "/a team cath"
      bob <## "#team: you have insufficient permissions for this action, the required role is admin"
      alice ##> "/mr team bob admin"
      concurrently_
        (alice <## "#team: you changed the role of bob from member to admin")
        (bob <## "#team: alice changed your role from member to admin")
      bob ##> "/a team cath owner"
      bob <## "#team: you have insufficient permissions for this action, the required role is owner"
      addMember "team" bob cath GRMember
      cath ##> "/j team"
      concurrentlyN_
        [ bob <## "#team: cath joined the group",
          do
            cath <## "#team: you joined the group"
            cath <## "#team: member alice (Alice) is connected",
          do
            alice <## "#team: bob added cath (Catherine) to the group (connecting...)"
            alice <## "#team: new member cath is connected"
        ]
      alice ##> "/mr team alice admin"
      concurrentlyN_
        [ alice <## "#team: you changed your role from owner to admin",
          bob <## "#team: alice changed the role from owner to admin",
          cath <## "#team: alice changed the role from owner to admin"
        ]
      alice ##> "/d #team"
      alice <## "#team: you have insufficient permissions for this action, the required role is owner"

testGroupDeleteUnusedContacts :: HasCallStack => FilePath -> IO ()
testGroupDeleteUnusedContacts =
  testChatCfg3 cfg aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      -- create group 1
      createGroup3 "team" alice bob cath
      -- create group 2
      alice ##> "/g club"
      alice <## "group #club is created"
      alice <## "to add members use /a club <name> or /create link #club"
      alice ##> "/a club bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #club sent to bob",
          do
            bob <## "#club: alice invites you to join the group as admin"
            bob <## "use /j club to accept"
        ]
      bob ##> "/j club"
      concurrently_
        (alice <## "#club: bob joined the group")
        (bob <## "#club: you joined the group")
      alice ##> "/a club cath"
      concurrentlyN_
        [ alice <## "invitation to join the group #club sent to cath",
          do
            cath <## "#club: alice invites you to join the group as admin"
            cath <## "use /j club to accept"
        ]
      cath ##> "/j club"
      concurrentlyN_
        [ alice <## "#club: cath joined the group",
          do
            cath <## "#club: you joined the group"
            cath <## "#club: member bob_1 (Bob) is connected"
            cath <## "contact bob_1 is merged into bob"
            cath <## "use @bob <message> to send messages",
          do
            bob <## "#club: alice added cath_1 (Catherine) to the group (connecting...)"
            bob <## "#club: new member cath_1 is connected"
            bob <## "contact cath_1 is merged into cath"
            bob <## "use @cath <message> to send messages"
        ]
      -- list contacts
      bob ##> "/contacts"
      bob <## "alice (Alice)"
      bob <## "cath (Catherine)"
      cath ##> "/contacts"
      cath <## "alice (Alice)"
      cath <## "bob (Bob)"
      -- delete group 1, contacts and profiles are kept
      deleteGroup alice bob cath "team"
      bob ##> "/contacts"
      bob <## "alice (Alice)"
      bob <## "cath (Catherine)"
      bob `hasContactProfiles` ["alice", "bob", "cath"]
      cath ##> "/contacts"
      cath <## "alice (Alice)"
      cath <## "bob (Bob)"
      cath `hasContactProfiles` ["alice", "bob", "cath"]
      -- delete group 2, unused contacts and profiles are deleted
      deleteGroup alice bob cath "club"
      threadDelay 3000000
      bob ##> "/contacts"
      bob <## "alice (Alice)"
      bob `hasContactProfiles` ["alice", "bob"]
      cath ##> "/contacts"
      cath <## "alice (Alice)"
      cath `hasContactProfiles` ["alice", "cath"]
  where
    cfg = testCfg {initialCleanupManagerDelay = 0, cleanupManagerInterval = 1, cleanupManagerStepDelay = 0}
    deleteGroup :: HasCallStack => TestCC -> TestCC -> TestCC -> String -> IO ()
    deleteGroup alice bob cath group = do
      alice ##> ("/d #" <> group)
      concurrentlyN_
        [ alice <## ("#" <> group <> ": you deleted the group"),
          do
            bob <## ("#" <> group <> ": alice deleted the group")
            bob <## ("use /d #" <> group <> " to delete the local copy of the group"),
          do
            cath <## ("#" <> group <> ": alice deleted the group")
            cath <## ("use /d #" <> group <> " to delete the local copy of the group")
        ]
      bob ##> ("/d #" <> group)
      bob <## ("#" <> group <> ": you deleted the group")
      cath ##> ("/d #" <> group)
      cath <## ("#" <> group <> ": you deleted the group")

testGroupDescription :: HasCallStack => FilePath -> IO ()
testGroupDescription = testChat4 aliceProfile bobProfile cathProfile danProfile $ \alice bob cath dan -> do
  connectUsers alice bob
  alice ##> "/g team"
  alice <## "group #team is created"
  alice <## "to add members use /a team <name> or /create link #team"
  addMember "team" alice bob GRAdmin
  bob ##> "/j team"
  concurrentlyN_
    [ alice <## "#team: bob joined the group",
      bob <## "#team: you joined the group"
    ]
  alice ##> "/group_profile team"
  alice <## "#team"
  groupInfo alice
  alice ##> "/group_descr team Welcome to the team!"
  alice <## "description changed to:"
  alice <## "Welcome to the team!"
  bob <## "alice updated group #team:"
  bob <## "description changed to:"
  bob <## "Welcome to the team!"
  alice ##> "/group_profile team"
  alice <## "#team"
  alice <## "description:"
  alice <## "Welcome to the team!"
  groupInfo alice
  connectUsers alice cath
  addMember "team" alice cath GRMember
  cath ##> "/j team"
  concurrentlyN_
    [ alice <## "#team: cath joined the group",
      do
        cath <## "#team: you joined the group"
        cath <# "#team alice> Welcome to the team!"
        cath <## "#team: member bob (Bob) is connected",
      do
        bob <## "#team: alice added cath (Catherine) to the group (connecting...)"
        bob <## "#team: new member cath is connected"
    ]
  connectUsers bob dan
  addMember "team" bob dan GRMember
  dan ##> "/j team"
  concurrentlyN_
    [ bob <## "#team: dan joined the group",
      do
        dan <## "#team: you joined the group"
        dan <# "#team bob> Welcome to the team!"
        dan
          <### [ "#team: member alice (Alice) is connected",
                 "#team: member cath (Catherine) is connected"
               ],
      bobAddedDan alice,
      bobAddedDan cath
    ]
  where
    groupInfo :: HasCallStack => TestCC -> IO ()
    groupInfo alice = do
      alice <## "group preferences:"
      alice <## "Disappearing messages: off"
      alice <## "Direct messages: on"
      alice <## "Full deletion: off"
      alice <## "Message reactions: on"
      alice <## "Voice messages: on"
      alice <## "Files and media: on"
    bobAddedDan :: HasCallStack => TestCC -> IO ()
    bobAddedDan cc = do
      cc <## "#team: bob added dan (Daniel) to the group (connecting...)"
      cc <## "#team: new member dan is connected"

testGroupModerate :: HasCallStack => FilePath -> IO ()
testGroupModerate =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      alice ##> "/mr team cath member"
      concurrentlyN_
        [ alice <## "#team: you changed the role of cath from admin to member",
          bob <## "#team: alice changed the role of cath from admin to member",
          cath <## "#team: alice changed your role from admin to member"
        ]
      alice #> "#team hello"
      concurrently_
        (bob <# "#team alice> hello")
        (cath <# "#team alice> hello")
      bob ##> "\\\\ #team @alice hello"
      bob <## "#team: you have insufficient permissions for this action, the required role is owner"
      threadDelay 1000000
      cath #> "#team hi"
      concurrently_
        (alice <# "#team cath> hi")
        (bob <# "#team cath> hi")
      bob ##> "\\\\ #team @cath hi"
      bob <## "message marked deleted by you"
      concurrently_
        (alice <# "#team cath> [marked deleted by bob] hi")
        (cath <# "#team cath> [marked deleted by bob] hi")
      alice #$> ("/_get chat #1 count=1", chat, [(0, "hi [marked deleted by bob]")])
      bob #$> ("/_get chat #1 count=1", chat, [(0, "hi [marked deleted by you]")])
      cath #$> ("/_get chat #1 count=1", chat, [(1, "hi [marked deleted by bob]")])

testGroupModerateFullDelete :: HasCallStack => FilePath -> IO ()
testGroupModerateFullDelete =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      alice ##> "/mr team cath member"
      concurrentlyN_
        [ alice <## "#team: you changed the role of cath from admin to member",
          bob <## "#team: alice changed the role of cath from admin to member",
          cath <## "#team: alice changed your role from admin to member"
        ]
      alice ##> "/set delete #team on"
      alice <## "updated group preferences:"
      alice <## "Full deletion: on"
      concurrentlyN_
        [ do
            bob <## "alice updated group #team:"
            bob <## "updated group preferences:"
            bob <## "Full deletion: on",
          do
            cath <## "alice updated group #team:"
            cath <## "updated group preferences:"
            cath <## "Full deletion: on"
        ]
      threadDelay 1000000
      cath #> "#team hi"
      concurrently_
        (alice <# "#team cath> hi")
        (bob <# "#team cath> hi")
      bob ##> "\\\\ #team @cath hi"
      bob <## "message deleted by you"
      concurrently_
        (alice <# "#team cath> [deleted by bob] hi")
        (cath <# "#team cath> [deleted by bob] hi")
      alice #$> ("/_get chat #1 count=1", chat, [(0, "moderated [deleted by bob]")])
      bob #$> ("/_get chat #1 count=1", chat, [(0, "moderated [deleted by you]")])
      cath #$> ("/_get chat #1 count=1", chat, [(1, "moderated [deleted by bob]")])

testGroupDelayedModeration :: HasCallStack => FilePath -> IO ()
testGroupDelayedModeration tmp = do
  withNewTestChat tmp "alice" aliceProfile $ \alice -> do
    withNewTestChat tmp "bob" bobProfile $ \bob -> do
      createGroup2 "team" alice bob
    withNewTestChat tmp "cath" cathProfile $ \cath -> do
      connectUsers alice cath
      addMember "team" alice cath GRMember
      cath ##> "/j team"
      concurrentlyN_
        [ alice <## "#team: cath joined the group",
          cath <## "#team: you joined the group"
        ]
      threadDelay 1000000
      cath #> "#team hi" -- message is pending for bob
      alice <# "#team cath> hi"
      alice ##> "\\\\ #team @cath hi"
      alice <## "message marked deleted by you"
      cath <# "#team cath> [marked deleted by alice] hi"
    withTestChat tmp "bob" $ \bob -> do
      bob <## "1 contacts connected (use /cs for the list)"
      bob <## "#team: connected to server(s)"
      bob <## "#team: alice added cath (Catherine) to the group (connecting...)"
      withTestChat tmp "cath" $ \cath -> do
        cath <## "2 contacts connected (use /cs for the list)"
        cath <## "#team: connected to server(s)"
        cath <## "#team: member bob (Bob) is connected"
        bob
          <### [ "#team: new member cath is connected",
                 EndsWith "#team cath> [marked deleted by alice] hi"
               ]
        alice #$> ("/_get chat #1 count=1", chat, [(0, "hi [marked deleted by you]")])
        cath #$> ("/_get chat #1 count=2", chat, [(1, "hi [marked deleted by alice]"), (0, "connected")])
        bob ##> "/_get chat #1 count=2"
        r <- chat <$> getTermLine bob
        r `shouldMatchList` [(0, "connected"), (0, "hi [marked deleted by alice]")]

testGroupDelayedModerationFullDelete :: HasCallStack => FilePath -> IO ()
testGroupDelayedModerationFullDelete tmp = do
  withNewTestChat tmp "alice" aliceProfile $ \alice -> do
    withNewTestChat tmp "bob" bobProfile $ \bob -> do
      createGroup2 "team" alice bob
    withNewTestChat tmp "cath" cathProfile $ \cath -> do
      connectUsers alice cath
      addMember "team" alice cath GRMember
      cath ##> "/j team"
      concurrentlyN_
        [ alice <## "#team: cath joined the group",
          cath <## "#team: you joined the group"
        ]
      threadDelay 1000000
      cath #> "#team hi" -- message is pending for bob
      alice <# "#team cath> hi"
      alice ##> "\\\\ #team @cath hi"
      alice <## "message marked deleted by you"
      cath <# "#team cath> [marked deleted by alice] hi"
      -- if full deletion was enabled at time of moderation, cath would delete pending message as well,
      -- that's why we set it afterwards to test delayed moderation for bob
      alice ##> "/set delete #team on"
      alice <## "updated group preferences:"
      alice <## "Full deletion: on"
      cath <## "alice updated group #team:"
      cath <## "updated group preferences:"
      cath <## "Full deletion: on"
    withTestChat tmp "bob" $ \bob -> do
      bob <## "1 contacts connected (use /cs for the list)"
      bob <## "#team: connected to server(s)"
      bob <## "#team: alice added cath (Catherine) to the group (connecting...)"
      bob <## "alice updated group #team:"
      bob <## "updated group preferences:"
      bob <## "Full deletion: on"
      withTestChat tmp "cath" $ \cath -> do
        cath <## "2 contacts connected (use /cs for the list)"
        cath <## "#team: connected to server(s)"
        cath <## "#team: member bob (Bob) is connected"
        bob
          <### [ "#team: new member cath is connected",
                 EndsWith "#team cath> moderated [deleted by alice]"
               ]
        alice #$> ("/_get chat #1 count=2", chat, [(0, "hi [marked deleted by you]"), (1, "Full deletion: on")])
        cath #$> ("/_get chat #1 count=3", chat, [(1, "hi [marked deleted by alice]"), (0, "Full deletion: on"), (0, "connected")])
        bob ##> "/_get chat #1 count=3"
        r <- chat <$> getTermLine bob
        r `shouldMatchList` [(0, "Full deletion: on"), (0, "connected"), (0, "moderated [deleted by alice]")]

testGroupAsync :: HasCallStack => FilePath -> IO ()
testGroupAsync tmp = do
  print (0 :: Integer)
  withNewTestChat tmp "alice" aliceProfile $ \alice -> do
    withNewTestChat tmp "bob" bobProfile $ \bob -> do
      connectUsers alice bob
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/a team bob"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to bob",
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## "use /j team to accept"
        ]
      bob ##> "/j team"
      concurrently_
        (alice <## "#team: bob joined the group")
        (bob <## "#team: you joined the group")
      alice #> "#team hello bob"
      bob <# "#team alice> hello bob"
  print (1 :: Integer)
  withTestChat tmp "alice" $ \alice -> do
    withNewTestChat tmp "cath" cathProfile $ \cath -> do
      alice <## "1 contacts connected (use /cs for the list)"
      alice <## "#team: connected to server(s)"
      connectUsers alice cath
      alice ##> "/a team cath"
      concurrentlyN_
        [ alice <## "invitation to join the group #team sent to cath",
          do
            cath <## "#team: alice invites you to join the group as admin"
            cath <## "use /j team to accept"
        ]
      cath ##> "/j team"
      concurrentlyN_
        [ alice <## "#team: cath joined the group",
          cath <## "#team: you joined the group"
        ]
      alice #> "#team hello cath"
      cath <# "#team alice> hello cath"
  print (2 :: Integer)
  withTestChat tmp "bob" $ \bob -> do
    withTestChat tmp "cath" $ \cath -> do
      concurrentlyN_
        [ do
            bob <## "1 contacts connected (use /cs for the list)"
            bob <## "#team: connected to server(s)"
            bob <## "#team: alice added cath (Catherine) to the group (connecting...)"
            bob <# "#team alice> hello cath"
            bob <## "#team: new member cath is connected",
          do
            cath <## "2 contacts connected (use /cs for the list)"
            cath <## "#team: connected to server(s)"
            cath <## "#team: member bob (Bob) is connected"
        ]
  threadDelay 500000
  print (3 :: Integer)
  withTestChat tmp "bob" $ \bob -> do
    withNewTestChat tmp "dan" danProfile $ \dan -> do
      bob <## "2 contacts connected (use /cs for the list)"
      bob <## "#team: connected to server(s)"
      connectUsers bob dan
      bob ##> "/a team dan"
      concurrentlyN_
        [ bob <## "invitation to join the group #team sent to dan",
          do
            dan <## "#team: bob invites you to join the group as admin"
            dan <## "use /j team to accept"
        ]
      dan ##> "/j team"
      concurrentlyN_
        [ bob <## "#team: dan joined the group",
          dan <## "#team: you joined the group"
        ]
      threadDelay 1000000
  threadDelay 1000000
  print (4 :: Integer)
  withTestChat tmp "alice" $ \alice -> do
    withTestChat tmp "cath" $ \cath -> do
      withTestChat tmp "dan" $ \dan -> do
        concurrentlyN_
          [ do
              alice <## "2 contacts connected (use /cs for the list)"
              alice <## "#team: connected to server(s)"
              alice <## "#team: bob added dan (Daniel) to the group (connecting...)"
              alice <## "#team: new member dan is connected",
            do
              cath <## "2 contacts connected (use /cs for the list)"
              cath <## "#team: connected to server(s)"
              cath <## "#team: bob added dan (Daniel) to the group (connecting...)"
              cath <## "#team: new member dan is connected",
            do
              dan <## "3 contacts connected (use /cs for the list)"
              dan <## "#team: connected to server(s)"
              dan <## "#team: member alice (Alice) is connected"
              dan <## "#team: member cath (Catherine) is connected"
          ]
        threadDelay 1000000
  print (5 :: Integer)
  withTestChat tmp "alice" $ \alice -> do
    withTestChat tmp "bob" $ \bob -> do
      withTestChat tmp "cath" $ \cath -> do
        withTestChat tmp "dan" $ \dan -> do
          concurrentlyN_
            [ do
                alice <## "3 contacts connected (use /cs for the list)"
                alice <## "#team: connected to server(s)",
              do
                bob <## "3 contacts connected (use /cs for the list)"
                bob <## "#team: connected to server(s)",
              do
                cath <## "3 contacts connected (use /cs for the list)"
                cath <## "#team: connected to server(s)",
              do
                dan <## "3 contacts connected (use /cs for the list)"
                dan <## "#team: connected to server(s)"
            ]
          alice #> "#team hello"
          concurrentlyN_
            [ bob <# "#team alice> hello",
              cath <# "#team alice> hello",
              dan <# "#team alice> hello"
            ]
          bob #> "#team hi there"
          concurrentlyN_
            [ alice <# "#team bob> hi there",
              cath <# "#team bob> hi there",
              dan <# "#team bob> hi there"
            ]
          cath #> "#team hey"
          concurrentlyN_
            [ alice <# "#team cath> hey",
              bob <# "#team cath> hey",
              dan <# "#team cath> hey"
            ]
          dan #> "#team how is it going?"
          concurrentlyN_
            [ alice <# "#team dan> how is it going?",
              bob <# "#team dan> how is it going?",
              cath <# "#team dan> how is it going?"
            ]
          bob <##> cath
          dan <##> cath
          dan <##> alice

testGroupLink :: HasCallStack => FilePath -> IO ()
testGroupLink =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/show link #team"
      alice <## "no group link, to create: /create link #team"
      alice ##> "/create link #team"
      _ <- getGroupLink alice "team" GRMember True
      alice ##> "/delete link #team"
      alice <## "Group link is deleted - joined members will remain connected."
      alice <## "To create a new group link use /create link #team"
      alice ##> "/create link #team"
      gLink <- getGroupLink alice "team" GRMember True
      alice ##> "/show link #team"
      _ <- getGroupLink alice "team" GRMember False
      alice ##> "/create link #team"
      alice <## "you already have link for this group, to show: /show link #team"
      bob ##> ("/c " <> gLink)
      bob <## "connection request sent!"
      alice <## "bob (Bob): accepting request to join group #team..."
      concurrentlyN_
        [ do
            alice <## "bob (Bob): contact is connected"
            alice <## "bob invited to group #team via your group link"
            alice <## "#team: bob joined the group",
          do
            bob <## "alice (Alice): contact is connected"
            bob <## "#team: you joined the group"
        ]
      threadDelay 100000
      alice #$> ("/_get chat #1 count=100", chat, [(0, "invited via your group link"), (0, "connected")])
      -- contacts connected via group link are not in chat previews
      alice @@@ [("#team", "connected")]
      bob @@@ [("#team", "connected")]
      alice <##> bob
      alice @@@ [("@bob", "hey"), ("#team", "connected")]

      -- user address doesn't interfere
      alice ##> "/ad"
      cLink <- getContactLink alice True
      cath ##> ("/c " <> cLink)
      alice <#? cath
      alice ##> "/ac cath"
      alice <## "cath (Catherine): accepting contact request..."
      concurrently_
        (cath <## "alice (Alice): contact is connected")
        (alice <## "cath (Catherine): contact is connected")
      alice <##> cath

      -- third member
      cath ##> ("/c " <> gLink)
      cath <## "connection request sent!"
      alice <## "cath_1 (Catherine): accepting request to join group #team..."
      -- if contact existed it is merged
      concurrentlyN_
        [ alice
            <### [ "cath_1 (Catherine): contact is connected",
                   "contact cath_1 is merged into cath",
                   "use @cath <message> to send messages",
                   EndsWith "invited to group #team via your group link",
                   EndsWith "joined the group"
                 ],
          cath
            <### [ "alice_1 (Alice): contact is connected",
                   "contact alice_1 is merged into alice",
                   "use @alice <message> to send messages",
                   "#team: you joined the group",
                   "#team: member bob (Bob) is connected"
                 ],
          do
            bob <## "#team: alice added cath (Catherine) to the group (connecting...)"
            bob <## "#team: new member cath is connected"
        ]
      alice #> "#team hello"
      concurrently_
        (bob <# "#team alice> hello")
        (cath <# "#team alice> hello")
      bob #> "#team hi there"
      concurrently_
        (alice <# "#team bob> hi there")
        (cath <# "#team bob> hi there")
      cath #> "#team hey team"
      concurrently_
        (alice <# "#team cath> hey team")
        (bob <# "#team cath> hey team")

      -- leaving team removes link
      alice ##> "/l team"
      concurrentlyN_
        [ do
            alice <## "#team: you left the group"
            alice <## "use /d #team to delete the group",
          bob <## "#team: alice left the group",
          cath <## "#team: alice left the group"
        ]
      alice ##> "/show link #team"
      alice <## "no group link, to create: /create link #team"

testGroupLinkDeleteGroupRejoin :: HasCallStack => FilePath -> IO ()
testGroupLinkDeleteGroupRejoin =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/create link #team"
      gLink <- getGroupLink alice "team" GRMember True
      bob ##> ("/c " <> gLink)
      bob <## "connection request sent!"
      alice <## "bob (Bob): accepting request to join group #team..."
      concurrentlyN_
        [ do
            alice <## "bob (Bob): contact is connected"
            alice <## "bob invited to group #team via your group link"
            alice <## "#team: bob joined the group",
          do
            bob <## "alice (Alice): contact is connected"
            bob <## "#team: you joined the group"
        ]
      -- use contact so it's not deleted when deleting group
      bob <##> alice
      bob ##> "/l team"
      concurrentlyN_
        [ do
            bob <## "#team: you left the group"
            bob <## "use /d #team to delete the group",
          alice <## "#team: bob left the group"
        ]
      bob ##> "/d #team"
      bob <## "#team: you deleted the group"
      -- re-join via same link
      bob ##> ("/c " <> gLink)
      bob <## "connection request sent!"
      alice <## "bob_1 (Bob): accepting request to join group #team..."
      concurrentlyN_
        [ alice
            <### [ "bob_1 (Bob): contact is connected",
                   "contact bob_1 is merged into bob",
                   "use @bob <message> to send messages",
                   EndsWith "invited to group #team via your group link",
                   EndsWith "joined the group"
                 ],
          bob
            <### [ "alice_1 (Alice): contact is connected",
                   "contact alice_1 is merged into alice",
                   "use @alice <message> to send messages",
                   "#team: you joined the group"
                 ]
        ]
      alice #> "#team hello"
      bob <# "#team alice> hello"
      bob #> "#team hi there"
      alice <# "#team bob> hi there"

testGroupLinkContactUsed :: HasCallStack => FilePath -> IO ()
testGroupLinkContactUsed =
  testChat2 aliceProfile bobProfile $
    \alice bob -> do
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/create link #team"
      gLink <- getGroupLink alice "team" GRMember True
      bob ##> ("/c " <> gLink)
      bob <## "connection request sent!"
      alice <## "bob (Bob): accepting request to join group #team..."
      concurrentlyN_
        [ do
            alice <## "bob (Bob): contact is connected"
            alice <## "bob invited to group #team via your group link"
            alice <## "#team: bob joined the group",
          do
            bob <## "alice (Alice): contact is connected"
            bob <## "#team: you joined the group"
        ]
      -- sending/receiving a message marks contact as used
      threadDelay 100000
      alice @@@ [("#team", "connected")]
      bob @@@ [("#team", "connected")]
      alice #> "@bob hello"
      bob <# "alice> hello"
      threadDelay 500000
      alice #$> ("/clear bob", id, "bob: all messages are removed locally ONLY")
      alice @@@ [("@bob", ""), ("#team", "connected")]
      bob #$> ("/clear alice", id, "alice: all messages are removed locally ONLY")
      bob @@@ [("@alice", ""), ("#team", "connected")]

testGroupLinkIncognitoMembership :: HasCallStack => FilePath -> IO ()
testGroupLinkIncognitoMembership =
  testChat4 aliceProfile bobProfile cathProfile danProfile $
    \alice bob cath dan -> do
      -- bob connected incognito to alice
      alice ##> "/c"
      inv <- getInvitation alice
      bob #$> ("/incognito on", id, "ok")
      bob ##> ("/c " <> inv)
      bob <## "confirmation sent!"
      bobIncognito <- getTermLine bob
      concurrentlyN_
        [ do
            bob <## ("alice (Alice): contact is connected, your incognito profile for this contact is " <> bobIncognito)
            bob <## "use /i alice to print out this incognito profile again",
          alice <## (bobIncognito <> ": contact is connected")
        ]
      bob #$> ("/incognito off", id, "ok")
      -- alice creates group
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      -- alice invites bob
      alice ##> ("/a team " <> bobIncognito)
      concurrentlyN_
        [ alice <## ("invitation to join the group #team sent to " <> bobIncognito),
          do
            bob <## "#team: alice invites you to join the group as admin"
            bob <## ("use /j team to join incognito as " <> bobIncognito)
        ]
      bob ##> "/j team"
      concurrently_
        (alice <## ("#team: " <> bobIncognito <> " joined the group"))
        (bob <## ("#team: you joined the group incognito as " <> bobIncognito))
      -- bob creates group link, cath joins
      bob ##> "/create link #team"
      gLink <- getGroupLink bob "team" GRMember True
      cath ##> ("/c " <> gLink)
      cath <## "connection request sent!"
      bob <## "cath (Catherine): accepting request to join group #team..."
      _ <- getTermLine bob
      concurrentlyN_
        [ do
            bob <## ("cath (Catherine): contact is connected, your incognito profile for this contact is " <> bobIncognito)
            bob <## "use /i cath to print out this incognito profile again"
            bob <## "cath invited to group #team via your group link"
            bob <## "#team: cath joined the group",
          do
            cath <## (bobIncognito <> ": contact is connected")
            cath <## "#team: you joined the group"
            cath <## "#team: member alice (Alice) is connected",
          do
            alice <## ("#team: " <> bobIncognito <> " added cath (Catherine) to the group (connecting...)")
            alice <## "#team: new member cath is connected"
        ]
      bob ?#> "@cath hi, I'm incognito"
      cath <# (bobIncognito <> "> hi, I'm incognito")
      cath #> ("@" <> bobIncognito <> " hey, I'm cath")
      bob ?<# "cath> hey, I'm cath"
      -- dan joins incognito
      dan #$> ("/incognito on", id, "ok")
      dan ##> ("/c " <> gLink)
      danIncognito <- getTermLine dan
      dan <## "connection request sent incognito!"
      bob <## (danIncognito <> ": accepting request to join group #team...")
      _ <- getTermLine bob
      _ <- getTermLine dan
      concurrentlyN_
        [ do
            bob <## (danIncognito <> ": contact is connected, your incognito profile for this contact is " <> bobIncognito)
            bob <## ("use /i " <> danIncognito <> " to print out this incognito profile again")
            bob <## (danIncognito <> " invited to group #team via your group link")
            bob <## ("#team: " <> danIncognito <> " joined the group"),
          do
            dan <## (bobIncognito <> ": contact is connected, your incognito profile for this contact is " <> danIncognito)
            dan <## ("use /i " <> bobIncognito <> " to print out this incognito profile again")
            dan <## ("#team: you joined the group incognito as " <> danIncognito)
            dan
              <### [ "#team: member alice (Alice) is connected",
                     "#team: member cath (Catherine) is connected"
                   ],
          do
            alice <## ("#team: " <> bobIncognito <> " added " <> danIncognito <> " to the group (connecting...)")
            alice <## ("#team: new member " <> danIncognito <> " is connected"),
          do
            cath <## ("#team: " <> bobIncognito <> " added " <> danIncognito <> " to the group (connecting...)")
            cath <## ("#team: new member " <> danIncognito <> " is connected")
        ]
      dan #$> ("/incognito off", id, "ok")
      bob ?#> ("@" <> danIncognito <> " hi, I'm incognito")
      dan ?<# (bobIncognito <> "> hi, I'm incognito")
      dan ?#> ("@" <> bobIncognito <> " hey, me too")
      bob ?<# (danIncognito <> "> hey, me too")
      alice #> "#team hello"
      concurrentlyN_
        [ bob ?<# "#team alice> hello",
          cath <# "#team alice> hello",
          dan ?<# "#team alice> hello"
        ]
      bob ?#> "#team hi there"
      concurrentlyN_
        [ alice <# ("#team " <> bobIncognito <> "> hi there"),
          cath <# ("#team " <> bobIncognito <> "> hi there"),
          dan ?<# ("#team " <> bobIncognito <> "> hi there")
        ]
      cath #> "#team hey"
      concurrentlyN_
        [ alice <# "#team cath> hey",
          bob ?<# "#team cath> hey",
          dan ?<# "#team cath> hey"
        ]
      dan ?#> "#team how is it going?"
      concurrentlyN_
        [ alice <# ("#team " <> danIncognito <> "> how is it going?"),
          bob ?<# ("#team " <> danIncognito <> "> how is it going?"),
          cath <# ("#team " <> danIncognito <> "> how is it going?")
        ]

testGroupLinkUnusedHostContactDeleted :: HasCallStack => FilePath -> IO ()
testGroupLinkUnusedHostContactDeleted =
  testChatCfg2 cfg aliceProfile bobProfile $
    \alice bob -> do
      -- create group 1
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/create link #team"
      gLinkTeam <- getGroupLink alice "team" GRMember True
      bob ##> ("/c " <> gLinkTeam)
      bob <## "connection request sent!"
      alice <## "bob (Bob): accepting request to join group #team..."
      concurrentlyN_
        [ do
            alice <## "bob (Bob): contact is connected"
            alice <## "bob invited to group #team via your group link"
            alice <## "#team: bob joined the group",
          do
            bob <## "alice (Alice): contact is connected"
            bob <## "#team: you joined the group"
        ]
      -- create group 2
      alice ##> "/g club"
      alice <## "group #club is created"
      alice <## "to add members use /a club <name> or /create link #club"
      alice ##> "/create link #club"
      gLinkClub <- getGroupLink alice "club" GRMember True
      bob ##> ("/c " <> gLinkClub)
      bob <## "connection request sent!"
      alice <## "bob_1 (Bob): accepting request to join group #club..."
      concurrentlyN_
        [ alice
            <### [ "bob_1 (Bob): contact is connected",
                   "contact bob_1 is merged into bob",
                   "use @bob <message> to send messages",
                   EndsWith "invited to group #club via your group link",
                   EndsWith "joined the group"
                 ],
          bob
            <### [ "alice_1 (Alice): contact is connected",
                   "contact alice_1 is merged into alice",
                   "use @alice <message> to send messages",
                   "#club: you joined the group"
                 ]
        ]
      -- list contacts
      bob ##> "/contacts"
      bob <## "alice (Alice)"
      -- delete group 1, host contact and profile are kept
      bobLeaveDeleteGroup alice bob "team"
      bob ##> "/contacts"
      bob <## "alice (Alice)"
      bob `hasContactProfiles` ["alice", "bob"]
      -- delete group 2, unused host contact and profile are deleted
      bobLeaveDeleteGroup alice bob "club"
      threadDelay 3000000
      bob ##> "/contacts"
      (bob </)
      bob `hasContactProfiles` ["bob"]
  where
    cfg = testCfg {initialCleanupManagerDelay = 0, cleanupManagerInterval = 1, cleanupManagerStepDelay = 0}
    bobLeaveDeleteGroup :: HasCallStack => TestCC -> TestCC -> String -> IO ()
    bobLeaveDeleteGroup alice bob group = do
      bob ##> ("/l " <> group)
      concurrentlyN_
        [ do
            bob <## ("#" <> group <> ": you left the group")
            bob <## ("use /d #" <> group <> " to delete the group"),
          alice <## ("#" <> group <> ": bob left the group")
        ]
      bob ##> ("/d #" <> group)
      bob <## ("#" <> group <> ": you deleted the group")

testGroupLinkIncognitoUnusedHostContactsDeleted :: HasCallStack => FilePath -> IO ()
testGroupLinkIncognitoUnusedHostContactsDeleted =
  testChatCfg2 cfg aliceProfile bobProfile $
    \alice bob -> do
      bob #$> ("/incognito on", id, "ok")
      bobIncognitoTeam <- createGroupBobIncognito alice bob "team" "alice"
      bobIncognitoClub <- createGroupBobIncognito alice bob "club" "alice_1"
      bobIncognitoTeam `shouldNotBe` bobIncognitoClub
      -- list contacts
      bob ##> "/contacts"
      bob <## "i alice (Alice)"
      bob <## "i alice_1 (Alice)"
      bob `hasContactProfiles` ["alice", "alice", "bob", T.pack bobIncognitoTeam, T.pack bobIncognitoClub]
      -- delete group 1, unused host contact and profile are deleted
      bobLeaveDeleteGroup alice bob "team" bobIncognitoTeam
      threadDelay 3000000
      bob ##> "/contacts"
      bob <## "i alice_1 (Alice)"
      bob `hasContactProfiles` ["alice", "bob", T.pack bobIncognitoClub]
      -- delete group 2, unused host contact and profile are deleted
      bobLeaveDeleteGroup alice bob "club" bobIncognitoClub
      threadDelay 3000000
      bob ##> "/contacts"
      (bob </)
      bob `hasContactProfiles` ["bob"]
  where
    cfg = testCfg {initialCleanupManagerDelay = 0, cleanupManagerInterval = 1, cleanupManagerStepDelay = 0}
    createGroupBobIncognito :: HasCallStack => TestCC -> TestCC -> String -> String -> IO String
    createGroupBobIncognito alice bob group bobsAliceContact = do
      alice ##> ("/g " <> group)
      alice <## ("group #" <> group <> " is created")
      alice <## ("to add members use /a " <> group <> " <name> or /create link #" <> group)
      alice ##> ("/create link #" <> group)
      gLinkTeam <- getGroupLink alice group GRMember True
      bob ##> ("/c " <> gLinkTeam)
      bobIncognito <- getTermLine bob
      bob <## "connection request sent incognito!"
      alice <## (bobIncognito <> ": accepting request to join group #" <> group <> "...")
      _ <- getTermLine bob
      concurrentlyN_
        [ do
            alice <## (bobIncognito <> ": contact is connected")
            alice <## (bobIncognito <> " invited to group #" <> group <> " via your group link")
            alice <## ("#" <> group <> ": " <> bobIncognito <> " joined the group"),
          do
            bob <## (bobsAliceContact <> " (Alice): contact is connected, your incognito profile for this contact is " <> bobIncognito)
            bob <## ("use /i " <> bobsAliceContact <> " to print out this incognito profile again")
            bob <## ("#" <> group <> ": you joined the group incognito as " <> bobIncognito)
        ]
      pure bobIncognito
    bobLeaveDeleteGroup :: HasCallStack => TestCC -> TestCC -> String -> String -> IO ()
    bobLeaveDeleteGroup alice bob group bobIncognito = do
      bob ##> ("/l " <> group)
      concurrentlyN_
        [ do
            bob <## ("#" <> group <> ": you left the group")
            bob <## ("use /d #" <> group <> " to delete the group"),
          alice <## ("#" <> group <> ": " <> bobIncognito <> " left the group")
        ]
      bob ##> ("/d #" <> group)
      bob <## ("#" <> group <> ": you deleted the group")

testGroupLinkMemberRole :: HasCallStack => FilePath -> IO ()
testGroupLinkMemberRole =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/create link #team admin"
      alice <## "#team: initial role for group member cannot be admin, use member or observer"
      alice ##> "/create link #team observer"
      gLink <- getGroupLink alice "team" GRObserver True
      bob ##> ("/c " <> gLink)
      bob <## "connection request sent!"
      alice <## "bob (Bob): accepting request to join group #team..."
      concurrentlyN_
        [ do
            alice <## "bob (Bob): contact is connected"
            alice <## "bob invited to group #team via your group link"
            alice <## "#team: bob joined the group",
          do
            bob <## "alice (Alice): contact is connected"
            bob <## "#team: you joined the group"
        ]
      alice ##> "/set link role #team admin"
      alice <## "#team: initial role for group member cannot be admin, use member or observer"
      alice ##> "/set link role #team member"
      _ <- getGroupLink alice "team" GRMember False
      cath ##> ("/c " <> gLink)
      cath <## "connection request sent!"
      alice <## "cath (Catherine): accepting request to join group #team..."
      -- if contact existed it is merged
      concurrentlyN_
        [ alice
            <### [ "cath (Catherine): contact is connected",
                   EndsWith "invited to group #team via your group link",
                   EndsWith "joined the group"
                 ],
          cath
            <### [ "alice (Alice): contact is connected",
                   "#team: you joined the group",
                   "#team: member bob (Bob) is connected"
                 ],
          do
            bob <## "#team: alice added cath (Catherine) to the group (connecting...)"
            bob <## "#team: new member cath is connected"
        ]
      alice #> "#team hello"
      concurrently_
        (bob <# "#team alice> hello")
        (cath <# "#team alice> hello")
      cath #> "#team hello too"
      concurrently_
        (alice <# "#team cath> hello too")
        (bob <# "#team cath> hello too")
      bob ##> "#team hey"
      bob <## "#team: you don't have permission to send messages"
      alice ##> "/mr #team bob member"
      alice <## "#team: you changed the role of bob from observer to member"
      concurrently_
        (bob <## "#team: alice changed your role from observer to member")
        (cath <## "#team: alice changed the role of bob from observer to member")
      bob #> "#team hey now"
      concurrently_
        (alice <# "#team bob> hey now")
        (cath <# "#team bob> hey now")

testGroupLinkLeaveDelete :: HasCallStack => FilePath -> IO ()
testGroupLinkLeaveDelete =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      connectUsers alice bob
      connectUsers cath bob
      alice ##> "/g team"
      alice <## "group #team is created"
      alice <## "to add members use /a team <name> or /create link #team"
      alice ##> "/create link #team"
      gLink <- getGroupLink alice "team" GRMember True
      bob ##> ("/c " <> gLink)
      bob <## "connection request sent!"
      alice <## "bob_1 (Bob): accepting request to join group #team..."
      concurrentlyN_
        [ alice
            <### [ "bob_1 (Bob): contact is connected",
                   "contact bob_1 is merged into bob",
                   "use @bob <message> to send messages",
                   EndsWith "invited to group #team via your group link",
                   EndsWith "joined the group"
                 ],
          bob
            <### [ "alice_1 (Alice): contact is connected",
                   "contact alice_1 is merged into alice",
                   "use @alice <message> to send messages",
                   "#team: you joined the group"
                 ]
        ]
      cath ##> ("/c " <> gLink)
      cath <## "connection request sent!"
      alice <## "cath (Catherine): accepting request to join group #team..."
      concurrentlyN_
        [ alice
            <### [ "cath (Catherine): contact is connected",
                   "cath invited to group #team via your group link",
                   "#team: cath joined the group"
                 ],
          cath
            <### [ "alice (Alice): contact is connected",
                   "#team: you joined the group",
                   "#team: member bob_1 (Bob) is connected",
                   "contact bob_1 is merged into bob",
                   "use @bob <message> to send messages"
                 ],
          bob
            <### [ "#team: alice added cath_1 (Catherine) to the group (connecting...)",
                   "#team: new member cath_1 is connected",
                   "contact cath_1 is merged into cath",
                   "use @cath <message> to send messages"
                 ]
        ]
      bob ##> "/l team"
      concurrentlyN_
        [ do
            bob <## "#team: you left the group"
            bob <## "use /d #team to delete the group",
          alice <## "#team: bob left the group",
          cath <## "#team: bob left the group"
        ]
      bob ##> "/contacts"
      bob <## "alice (Alice)"
      bob <## "cath (Catherine)"
      bob ##> "/d #team"
      bob <## "#team: you deleted the group"
      bob ##> "/contacts"
      bob <## "alice (Alice)"
      bob <## "cath (Catherine)"

testGroupMsgDecryptError :: HasCallStack => FilePath -> IO ()
testGroupMsgDecryptError tmp =
  withNewTestChat tmp "alice" aliceProfile $ \alice -> do
    withNewTestChat tmp "cath" cathProfile $ \cath -> do
      withNewTestChat tmp "bob" bobProfile $ \bob -> do
        createGroup3 "team" alice bob cath
        alice #> "#team hi"
        [bob, cath] *<# "#team alice> hi"
        bob #> "#team hey"
        [alice, cath] *<# "#team bob> hey"
      setupDesynchronizedRatchet tmp alice cath
      withTestChat tmp "bob" $ \bob -> do
        bob <## "2 contacts connected (use /cs for the list)"
        bob <## "#team: connected to server(s)"
        alice #> "#team hello again"
        bob <# "#team alice> skipped message ID 8..10"
        [bob, cath] *<# "#team alice> hello again"
        bob #> "#team received!"
        alice <# "#team bob> received!"
        cath <# "#team bob> received!"

setupDesynchronizedRatchet :: HasCallStack => FilePath -> TestCC -> TestCC -> IO ()
setupDesynchronizedRatchet tmp alice cath = do
  copyDb "bob" "bob_old"
  withTestChat tmp "bob" $ \bob -> do
    bob <## "2 contacts connected (use /cs for the list)"
    bob <## "#team: connected to server(s)"
    alice #> "#team hello"
    [bob, cath] *<# "#team alice> hello"
    bob #> "#team hello too"
    [alice, cath] *<# "#team bob> hello too"
  withTestChat tmp "bob_old" $ \bob -> do
    bob <## "2 contacts connected (use /cs for the list)"
    bob <## "#team: connected to server(s)"
    bob ##> "/sync #team alice"
    bob <## "error: command is prohibited"
    alice #> "#team 1"
    bob <## "#team alice: decryption error (connection out of sync), synchronization required"
    bob <## "use /sync #team alice to synchronize"
    cath <# "#team alice> 1"
    alice #> "#team 2"
    cath <# "#team alice> 2"
    alice #> "#team 3"
    cath <# "#team alice> 3"
    (bob </)
    bob ##> "/tail #team 1"
    bob <# "#team alice> decryption error, possibly due to the device change (header, 3 messages)"
  where
    copyDb from to = do
      copyFile (chatStoreFile $ tmp </> from) (chatStoreFile $ tmp </> to)
      copyFile (agentStoreFile $ tmp </> from) (agentStoreFile $ tmp </> to)

testGroupSyncRatchet :: HasCallStack => FilePath -> IO ()
testGroupSyncRatchet tmp =
  withNewTestChat tmp "alice" aliceProfile $ \alice -> do
    withNewTestChat tmp "cath" cathProfile $ \cath -> do
      withNewTestChat tmp "bob" bobProfile $ \bob -> do
        createGroup3 "team" alice bob cath
        alice #> "#team hi"
        [bob, cath] *<# "#team alice> hi"
        bob #> "#team hey"
        [alice, cath] *<# "#team bob> hey"
      setupDesynchronizedRatchet tmp alice cath
      withTestChat tmp "bob_old" $ \bob -> do
        bob <## "2 contacts connected (use /cs for the list)"
        bob <## "#team: connected to server(s)"
        -- cath and bob are not fully de-synchronized
        bob `send` "#team 1"
        bob <## "error: command is prohibited" -- silence?
        bob <# "#team 1"
        (alice </)
        (cath </)
        cath #> "#team 1"
        [alice, bob] *<# "#team cath> 1"
        bob `send` "#team 2"
        bob <## "error: command is prohibited"
        bob <# "#team 2"
        cath <# "#team bob> incorrect message hash"
        cath <# "#team bob> 2"
        bob `send` "#team 3"
        bob <## "error: command is prohibited"
        bob <# "#team 3"
        cath <# "#team bob> 3"
        -- synchronize bob and alice
        bob ##> "/sync #team alice"
        bob <## "connection synchronization started"
        alice <## "#team bob: connection synchronization agreed"
        bob <## "#team alice: connection synchronization agreed"
        alice <## "#team bob: connection synchronized"
        bob <## "#team alice: connection synchronized"

        bob #$> ("/_get chat #1 count=3", chat, [(1, "connection synchronization started for alice"), (0, "connection synchronization agreed"), (0, "connection synchronized")])
        alice #$> ("/_get chat #1 count=2", chat, [(0, "connection synchronization agreed"), (0, "connection synchronized")])

        alice #> "#team hello again"
        [bob, cath] *<# "#team alice> hello again"
        bob #> "#team received!"
        alice <# "#team bob> received!"
        cath <# "#team bob> received!"

testGroupSyncRatchetCodeReset :: HasCallStack => FilePath -> IO ()
testGroupSyncRatchetCodeReset tmp =
  withNewTestChat tmp "alice" aliceProfile $ \alice -> do
    withNewTestChat tmp "cath" cathProfile $ \cath -> do
      withNewTestChat tmp "bob" bobProfile $ \bob -> do
        createGroup3 "team" alice bob cath
        alice #> "#team hi"
        [bob, cath] *<# "#team alice> hi"
        bob #> "#team hey"
        [alice, cath] *<# "#team bob> hey"
        -- connection not verified
        bob ##> "/i #team alice"
        aliceInfo bob
        bob <## "connection not verified, use /code command to see security code"
        -- verify connection
        alice ##> "/code #team bob"
        bCode <- getTermLine alice
        bob ##> ("/verify #team alice " <> bCode)
        bob <## "connection verified"
        -- connection verified
        bob ##> "/i #team alice"
        aliceInfo bob
        bob <## "connection verified"
      setupDesynchronizedRatchet tmp alice cath
      withTestChat tmp "bob_old" $ \bob -> do
        bob <## "2 contacts connected (use /cs for the list)"
        bob <## "#team: connected to server(s)"
        bob ##> "/sync #team alice"
        bob <## "connection synchronization started"
        alice <## "#team bob: connection synchronization agreed"
        bob <## "#team alice: connection synchronization agreed"
        bob <## "#team alice: security code changed"
        alice <## "#team bob: connection synchronized"
        bob <## "#team alice: connection synchronized"

        bob #$> ("/_get chat #1 count=4", chat, [(1, "connection synchronization started for alice"), (0, "connection synchronization agreed"), (0, "security code changed"), (0, "connection synchronized")])
        alice #$> ("/_get chat #1 count=2", chat, [(0, "connection synchronization agreed"), (0, "connection synchronized")])

        -- connection not verified
        bob ##> "/i #team alice"
        aliceInfo bob
        bob <## "connection not verified, use /code command to see security code"

        alice #> "#team hello again"
        [bob, cath] *<# "#team alice> hello again"
        bob #> "#team received!"
        alice <# "#team bob> received!"
        (cath </) -- bob is partially de-synchronized with cath - see test above
  where
    aliceInfo :: HasCallStack => TestCC -> IO ()
    aliceInfo bob = do
      bob <## "group ID: 1"
      bob <## "member ID: 1"
      bob <## "receiving messages via: localhost"
      bob <## "sending messages via: localhost"

testSetGroupMessageReactions :: HasCallStack => FilePath -> IO ()
testSetGroupMessageReactions =
  testChat3 aliceProfile bobProfile cathProfile $
    \alice bob cath -> do
      createGroup3 "team" alice bob cath
      threadDelay 1000000
      alice #> "#team hi"
      bob <# "#team alice> hi"
      cath <# "#team alice> hi"
      bob ##> "+1 #team hi"
      bob <## "added 👍"
      alice <# "#team bob> > alice hi"
      alice <## "    + 👍"
      cath <# "#team bob> > alice hi"
      cath <## "    + 👍"
      bob ##> "+1 #team hi"
      bob <## "bad chat command: reaction already added"
      bob ##> "+^ #team hi"
      bob <## "added 🚀"
      alice <# "#team bob> > alice hi"
      alice <## "    + 🚀"
      cath <# "#team bob> > alice hi"
      cath <## "    + 🚀"
      alice ##> "/tail #team 1"
      alice <# "#team hi"
      alice <## "      👍 1 🚀 1"
      bob ##> "/tail #team 1"
      bob <# "#team alice> hi"
      bob <## "      👍 1 🚀 1"
      bob ##> "/tail #team 1"
      bob <# "#team alice> hi"
      bob <## "      👍 1 🚀 1"
      alice ##> "+1 #team hi"
      alice <## "added 👍"
      bob <# "#team alice> > alice hi"
      bob <## "    + 👍"
      cath <# "#team alice> > alice hi"
      cath <## "    + 👍"
      alice ##> "/tail #team 1"
      alice <# "#team hi"
      alice <## "      👍 2 🚀 1"
      bob ##> "/tail #team 1"
      bob <# "#team alice> hi"
      bob <## "      👍 2 🚀 1"
      cath ##> "/tail #team 1"
      cath <# "#team alice> hi"
      cath <## "      👍 2 🚀 1"
      bob ##> "-1 #team hi"
      bob <## "removed 👍"
      alice <# "#team bob> > alice hi"
      alice <## "    - 👍"
      cath <# "#team bob> > alice hi"
      cath <## "    - 👍"
      bob ##> "-^ #team hi"
      bob <## "removed 🚀"
      alice <# "#team bob> > alice hi"
      alice <## "    - 🚀"
      cath <# "#team bob> > alice hi"
      cath <## "    - 🚀"
      alice ##> "/tail #team 1"
      alice <# "#team hi"
      alice <## "      👍 1"
      bob ##> "/tail #team 1"
      bob <# "#team alice> hi"
      bob <## "      👍 1"
      cath ##> "/tail #team 1"
      cath <# "#team alice> hi"
      cath <## "      👍 1"
