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
import Encrypt
import Control.Applicative ((<$>))
import Control.Monad.State.Lazy
import Control.Monad.Identity
import Data.List (foldl')
import Data.Time
import Data.Char
import Data.Time.LocalTime
import Data.Time.Calendar
import Text.Parsec
import qualified Data.Set as S
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
      (Right out, state) -> Right (out,state)

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
            NicksMessage   -> parseNicksMessage >> return [NoAction]
            NickMessage    -> parseNickMessage >> return [NoAction]
            PartMessage    -> parsePartMessage >> return [NoAction]
            JoinMessage    -> parseJoinMessage >> return [NoAction]
            PingMessage    -> return [Pong]
            OtherMessage   -> return [NoAction]
      in case runIRCParser parser "" str oldState of
            Left _            -> ([NoAction], oldState)
            Right actAndState -> actAndState

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
    "!id"        -> parseCommandId
    "!tell"      -> parseCommandTell
    "!afk"       -> parseCommandAfk
    "!waitforit" -> parseCommandWaitForIt
    "!say"       -> parseCommandSay
    "!rejoin"    -> return [ReJoin]
    _            -> return [NoAction]

parseCommandId :: IRCParser [IRCAction]
parseCommandId = do 
  text <- T.pack <$> many anyChar
  nick <- getMsgContextSenderNick
  chan <- getMsgContextChannel
  t    <- getMsgContextTime
  let time = T.pack $ show t
  return $ [PrivMsg $ T.concat [nick, " said \"", text
                              ,"\" in ", chan, " at ", time]]

parseCommandTell :: IRCParser [IRCAction]
parseCommandTell = do
  recipient <- parseWord
  msg <- fmap T.pack $ many1 anyChar

  cntxt <- getMessageContext
  let userMsg = UserMessage (msg, cntxt)

  userMsgs <- getUserMessages
  putUserMessages (M.insertWith (++) recipient [userMsg] userMsgs)
  return $ [PrivMsg "I will tell it them, as soon as i see them"]

parseCommandAfk :: IRCParser [IRCAction]
parseCommandAfk = do
  sender <- getMsgContextSenderNick
  isAfk <- M.member sender <$> getAfkUsers
  if isAfk then (do removeAfkUser sender
                    return [PrivMsg "You are no longer afk"])
           else (do msgCntxt <- getMessageContext
                    msg <- T.pack <$> many anyChar
                    case msg of
                     "" -> addAfkUserWithMessage sender Nothing
                     _  -> addAfkUserWithMessage sender
                             $ Just $ UserMessage (msg,msgCntxt)
                    return [PrivMsg "You are now afk"])

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

parseNicksMessage :: IRCParser ()
parseNicksMessage = do
  parseWord
  parseWord
  parseWord
  parseWord
  parseWord
  char ':'
  nicks <- many parseNick
  putOnlineUsers $ S.fromList nicks

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

getOnlineUsers :: IRCParser (S.Set User)
getOnlineUsers = gets $ onlineUsers . ircState

getAfkUsers :: IRCParser (M.Map User (Maybe UserMessage))
getAfkUsers = gets $ afkUsers . ircState

getTimedActions :: IRCParser [(UTCTime, [IRCAction])]
getTimedActions = gets $ timedActions . ircState

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

putOnlineUsers :: S.Set User -> IRCParser ()
putOnlineUsers new = do
  old <- getIRCState
  putIRCState $ old { onlineUsers = new }

putAfkUsers new = do
  old <- getIRCState
  putIRCState $ old { afkUsers = new }

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
  putOnlineUsers $ S.insert usr old

removeOnlineUser :: User -> IRCParser ()
removeOnlineUser usr = do
  old <- getOnlineUsers
  putOnlineUsers $ S.delete usr old

addAfkUserWithMessage :: User -> Maybe UserMessage -> IRCParser ()
addAfkUserWithMessage usr msg = do
  old <- getAfkUsers
  putAfkUsers $ M.insert usr msg old

removeAfkUser :: User -> IRCParser ()
removeAfkUser usr = do
  old <- getAfkUsers
  putAfkUsers $ M.delete usr old

addTimedAction :: (UTCTime, [IRCAction]) -> IRCParser ()
addTimedAction timedAct = do
  old <- getTimedActions
  putTimedActions (timedAct:old)
