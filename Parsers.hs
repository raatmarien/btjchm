{-# LANGUAGE OverloadedStrings #-}
module Parsers ( User
               , UserMessage(..)
               , IRCState(..)
               , MessageContext(..)
               , IRCParserState(..)
               , IRCAction(..)
               , parseMessage
               ) where

import Core
import Color
import Ascii
import Control.Applicative ((<$>))
import qualified Control.Applicative as A
import Control.Monad.State.Lazy
import Data.Maybe
import Data.Time
import Data.Char
import Data.List
import Text.Parsec
import qualified Data.Map as M
import qualified Data.Text as T

-- |A data type representing the state of the IRC Parser as wel as the
-- whole IRC State.
data IRCParserState =
    IRCParserState { ircState :: IRCState
                   , messageContext :: MessageContext
                   } deriving Show

-- |The IRCParser Monad, used for parsing messages. Incorporates the
-- State Monad and the Parsec Monad.
type IRCParser a = ParsecT T.Text ()
                   (Control.Monad.State.Lazy.State IRCParserState) a

-- |Run a IRCParser
runIRCParser :: IRCParser a -> SourceName -> T.Text
             -> IRCParserState -> Either ParseError (a,IRCParserState)
runIRCParser p s t st =
    case runState (runParserT p () s t) st of
      (Left err, _) -> Left err
      (Right out, stt) -> Right (out, stt)

-------------------------------------------------------------------------------- 

-- | Represents an message
data MessageType = PrivateMessage
                 | NicksMessage
                 | NickMessage
                 | PartMessage
                 | JoinMessage
                 | PingMessage
                 | OtherMessage

parseMessageType :: Parsec T.Text () MessageType
parseMessageType = do
  isPing <- parseWord
  case isPing of
    "PING" -> return PingMessage
    _      -> do 
      msgType <- parseWord
      case msgType of
          "PRIVMSG" -> return PrivateMessage
          "353"     -> return NicksMessage
          "NICK"    -> return NickMessage
          "PART"    -> return PartMessage
          "QUIT"    -> return PartMessage
          "JOIN"    -> return JoinMessage
          "PING"    -> return PingMessage
          _         -> return OtherMessage

parseMessage :: T.Text -> IRCParserState -> ([IRCAction], IRCParserState)
parseMessage str oldState =
  case runParser parseMessageType () "" str of
    Left _  -> ([NoAction], oldState)
    Right t ->
      let parser = case t of
            PrivateMessage -> parsePrivateMessage
            NicksMessage   -> parseNicksMessage >> return introMessage
            NickMessage    -> parseNickMessage >> return [NoAction]
            PartMessage    -> parsePartMessage >> return [NoAction]
            JoinMessage    -> parseJoinMessage >> return [NoAction]
            PingMessage    -> return [Pong]
            OtherMessage   -> return [NoAction]
      in case runIRCParser parser "" str oldState of
            Left _            -> ([NoAction], oldState)
            Right actAndState -> actAndState

introMessage,newsMessage :: [IRCAction]
introMessage = [PrivMsg $ T.concat
                [ "Hey everybody, to see what's new just use ", bold
                , "!whatsnew", reset]]
newsMessage =
  [PrivMsg "What's new in btjchm: \
           \you can now use !where <nick> to see if someone's online"]

parsePrivateMessage :: IRCParser [IRCAction]
parsePrivateMessage = do
  char ':'
  nick <- parseTill '!'
  putMsgContextSenderNick nick
  senderRest <- parseWord
  putMsgContextSenderFull (T.concat [nick,senderRest])
  parseWord
  chan <- parseWord
  putMsgContextChannel chan
  char ':'
  command <- parseWord
  case command of
    "!tell"      -> parseCommandTell
    "!afk"       -> parseCommandAfk
    "!where"     -> parseCommandWhere
    "!back"      -> parseCommandBack
    "!remind"    -> parseCommandRemind
    "!waitforit" -> parseCommandWaitForIt
    "!whatsnew"  -> return newsMessage
    "!say"       -> parseCommandSay
    "!rejoin"    -> return [ReJoin]
    "!ascii"     -> parseCommandAscii
    "!ok"        -> return messageOk
    "!pls"       -> return messagePls
    "n1"         -> return messageN1
    "--key--"    -> do key <- getKey
                       return [Debug $ T.concat
                               [ "--- Key ---\n", key
                               , "\n"]]
    "--debug--"  -> do state <- getIRCState
                       real <- authenticate
                       if real
                         then return [Debug $ T.pack $ show state]
                         else return []
    "--nick--"   -> do n <- parseWord
                       real <- authenticate
                       if real
                         then return [ChangeNick n]
                         else return []
    _            -> return []

authenticate = do realKey <- getKey
                  givenKey <- parseWord
                  return (realKey == givenKey)

parseCommandTell :: IRCParser [IRCAction]
parseCommandTell = do
  recipient <- parseWord
  msg <- T.pack <$> many1 anyChar

  cntxt <- getMessageContext
  let userMsg = UserMessage (msg, cntxt)

  userMsgs <- getUserMessages
  putUserMessages (M.insertWith (++) recipient [userMsg] userMsgs)
  return [PrivMsg "I will tell it them, as soon as i see them"]

parseCommandAfk :: IRCParser [IRCAction]
parseCommandAfk = do
  sender <- getMsgContextSenderNick
  isAfk <- (isJust . M.findWithDefault Nothing sender) <$> getOnlineUsers
  msgCntxt <- getMessageContext
  msg <- T.pack <$> many anyChar
  addAfkUserWithMessage sender
    $ UserMessage (msg,msgCntxt)
  if isAfk then (return [PrivMsg $ T.concat
                   [ "You were already afk, \
                     \your new afk message is: \""
                   , msg, "\""]])
           else (return [PrivMsg "You are now afk"])

parseCommandWhere :: IRCParser [IRCAction]
parseCommandWhere = do
  sender <- getMsgContextSenderNick
  who <- parseWord
  users <- getOnlineUsers
  let maybeOnline = M.lookup who users
  case maybeOnline of
   Nothing -> return [PrivMsg $ T.concat
                      [fColor Orange, sender, ": ", who, " is offline."]]
   Just maybeMsg -> case maybeMsg of
     Nothing -> return [PrivMsg $ T.concat
                        [fColor Green, sender, ": ", who, " is online."]]
     Just (UserMessage (msg,cntxt)) -> return [PrivMsg $ T.concat
                         [ fColor Yellow, sender, ": ", who
                         , " is afk: \"", msg, "\"."]]

parseCommandBack :: IRCParser [IRCAction]
parseCommandBack = do
  sender <- getMsgContextSenderNick
  isAfk <- (isJust . M.findWithDefault Nothing sender) <$> getOnlineUsers
  if isAfk then (do removeAfkUser sender
                    return [PrivMsg "Welcome back!"])
           else (return [PrivMsg "You are already back, use !afk"])

parseCommandRemind :: IRCParser [IRCAction]
parseCommandRemind = do
  currentTime <- getMsgContextTime
  recipient <- parseWord
  number <- manyTill digit (try $ char ' ')
  unit <- oneOf "smh"
  char ' '
  recipient' <- case recipient of
                  "me" -> getMsgContextSenderNick
                  _    -> return recipient
  let multiplier = case unit of
        's' -> 1
        'm' -> 60
        'h' -> 3600
      n = read number :: Int
      seconds = n * multiplier
      actionTime = addUTCTime (fromIntegral seconds) currentTime
  msg <- T.pack <$> many1 anyChar
  addTimedAction (actionTime, [PrivMsg $ T.concat [recipient'
                                                  ,": ", msg]])
  return [PrivMsg "Will do!"]

parseCommandWaitForIt :: IRCParser [IRCAction]
parseCommandWaitForIt = do
  timeToWait <- parseWord
  currentTime <- getMsgContextTime

  extraSeconds <- if all isDigit $ T.unpack timeToWait
                  then return (read $ T.unpack timeToWait :: Integer)
                  else fail "Couldn't parse Integer"
  let actionTime = addUTCTime (fromIntegral extraSeconds) currentTime

  addTimedAction (actionTime, [PrivMsg "DARY", PrivMsg "LEGENDARY!!!"])
  return [PrivMsg "LEGEN", PrivMsg "wait for it..."]
         
parseCommandSay :: IRCParser [IRCAction]
parseCommandSay = do
  txt <- T.pack <$> many anyChar
  return [PrivMsg txt]

parseCommandAscii :: IRCParser [IRCAction]
parseCommandAscii = do
   txt <- many anyChar 
   return $ if (length txt) < 30
            then map PrivMsg $ map T.pack $ foldl1' (zipWith (++))
                 $ map toAscii $ map toLower txt
            else []

parseNicksMessage :: IRCParser ()
parseNicksMessage = do
  parseWord
  parseWord
  parseWord
  parseWord
  parseWord
  char ':'
  nicks <- many parseNick
  putOnlineUsers $ M.fromList $ zip nicks (repeat Nothing)

parseNick :: IRCParser User
parseNick = do
  try (string "@") <|> try (string "+") <|> return ""
  parseWord
  
parseNickMessage :: IRCParser ()
parseNickMessage = do
  char ':'
  oldNick <- parseTill '!'
  parseWord
  parseWord
  char ':'
  newNick <- parseWord
  removeOnlineUser oldNick
  addOnlineUser newNick

parsePartMessage :: IRCParser ()
parsePartMessage = do
  char ':'
  nick <- parseTill '!'
  removeOnlineUser nick

parseJoinMessage :: IRCParser ()
parseJoinMessage = do
  char ':'
  nick <- parseTill '!'
  addOnlineUser nick

parseWord :: Monad m => ParsecT T.Text u m T.Text
parseWord = try (parseTill ' ') <|> T.pack <$> many1 anyChar
parseTill :: Monad m => Char -> ParsecT T.Text u m T.Text
parseTill c = T.pack <$> manyTill anyChar (try (char c))

-- Getters, because I cant get ghci to work on arm -> so no TemplateHaskell,
-- which means I can't use lenses, and this is my workaround.
getIRCState :: IRCParser IRCState
getIRCState = gets ircState

getMessageContext :: IRCParser MessageContext
getMessageContext = gets messageContext

getUserMessages :: IRCParser (M.Map User [UserMessage])
getUserMessages = gets $ userMessages . ircState

getOnlineUsers :: IRCParser (M.Map User (Maybe UserMessage))
getOnlineUsers = gets $ onlineUsers . ircState

getTimedActions :: IRCParser [(UTCTime, [IRCAction])]
getTimedActions = gets $ timedActions . ircState

getKey :: IRCParser T.Text
getKey = gets $ key . ircState

getMsgContextSenderNick :: IRCParser T.Text
getMsgContextSenderNick = gets $ msgContextSenderNick . messageContext

getMsgContextSenderFull :: IRCParser T.Text
getMsgContextSenderFull = gets $ msgContextSenderFull . messageContext

getMsgContextChannel :: IRCParser T.Text
getMsgContextChannel = gets $ msgContextChannel . messageContext

getMsgContextTime :: IRCParser UTCTime
getMsgContextTime = gets $ msgContextTime . messageContext

-- Putters, same reason
putIRCState :: IRCState -> IRCParser ()
putIRCState new = do 
  old <- get
  put $ old { ircState = new }

putMessageContext :: MessageContext -> IRCParser ()
putMessageContext new = do 
  old <- get
  put $ old { messageContext = new }

putUserMessages :: M.Map User [UserMessage] -> IRCParser ()
putUserMessages new = do 
  old <- getIRCState
  putIRCState $ old { userMessages = new }

putOnlineUsers :: M.Map User (Maybe UserMessage) -> IRCParser ()
putOnlineUsers new = do
  old <- getIRCState
  putIRCState $ old { onlineUsers = new }

putTimedActions :: [(UTCTime, [IRCAction])] -> IRCParser ()
putTimedActions new = do
  old <- getIRCState
  putIRCState $ old { timedActions = new }

putMsgContextSenderNick :: T.Text -> IRCParser ()
putMsgContextSenderNick new = do
  old <- getMessageContext
  putMessageContext $ old { msgContextSenderNick = new }

putMsgContextSenderFull :: T.Text -> IRCParser ()
putMsgContextSenderFull new = do
  old <- getMessageContext
  putMessageContext $ old { msgContextSenderFull = new }

putMsgContextChannel :: T.Text -> IRCParser ()
putMsgContextChannel new = do
  old <- getMessageContext
  putMessageContext $ old { msgContextChannel = new }

putMsgContextTime :: UTCTime -> IRCParser ()
putMsgContextTime new = do
  old <- getMessageContext
  putMessageContext $ old { msgContextTime = new }

-- Utility functions
addOnlineUser :: User -> IRCParser ()
addOnlineUser usr = do
  old <- getOnlineUsers
  putOnlineUsers $ M.insert usr Nothing old

removeOnlineUser :: User -> IRCParser ()
removeOnlineUser usr = do
  old <- getOnlineUsers
  putOnlineUsers $ M.delete usr old

addAfkUserWithMessage :: User -> UserMessage -> IRCParser ()
addAfkUserWithMessage usr msg = do
  old <- getOnlineUsers
  putOnlineUsers $ M.insert usr (Just msg) old

removeAfkUser :: User -> IRCParser ()
removeAfkUser usr = do
  old <- getOnlineUsers
  putOnlineUsers $ M.insert usr Nothing old

addTimedAction :: (UTCTime, [IRCAction]) -> IRCParser ()
addTimedAction timedAct = do
  old <- getTimedActions
  putTimedActions (timedAct:old)
