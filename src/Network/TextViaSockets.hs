{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE CPP #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Network.TextViaSockets
-- Copyright   :  (c) Damian Nadales 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Damian Nadales <damian.nadales@gmail.com>
-- Stability   :  provisional
-- Portability :  non-portable (requires concurrency)
--
-- Simple line-based text communication via sockets.
-----------------------------------------------------------------------------

module Network.TextViaSockets
    ( Connection ()
    -- * Connect to a server
    , connectTo
    -- * Same as connectTo, 
    -- but only creates the socket without setting up a connection
    , connectToSocket
    -- * Start a server
    , listenOn
    , acceptOn
    , acceptOnSocket
    , getFreeSocket
    -- * Sending and receiving data
    , getLineFrom
    , receiveMsgs
    , putLineTo
    , sendMsgs
    -- * Closing the connection
    , close
    ) where

import           Network.Socket hiding (close)
import           Network.Socket.ByteString
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM.TQueue
import           Control.Concurrent.STM
import           Data.Maybe
import           Data.Text.Encoding.Error
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Control.Exception.Base
import           Data.Foldable
import           Control.Retry
import           Control.Monad.Catch (Handler)
    
#ifdef DEBUG
import           Debug.Trace
#else
import           Copied_dependencies.Debug.NoTrace
#endif

-- | A connection for sending and receiving @Text@ lines.
data Connection = Connection
    { -- | Socket on which to send and receive data.
      connSock :: ! Socket
      -- | Server socket. It exists only if the connection was started on server mode.
    , serverSock :: !(Maybe Socket)
    , linesTQ :: !(TQueue Text)
    , socketReaderTid :: !ThreadId
    } deriving (Eq)

instance Show Connection where
    show Connection {connSock} =
        "Connection: socket = " ++ show connSock

-- | We always retry an IO Exception.
retryIOException :: IOException -> IO Bool
retryIOException _ = return True

-- | How to report an IOException.
reportIOException :: Bool        -- ^ Is the action being retried or are we giving up?
                  -> IOException -- ^ Exception that was raised.
                  -> RetryStatus -- ^ Contains the number of iterations, delay so far, and last delay.
                  -> IO ()
reportIOException _ ex rs = do
        traceIO $ "Got exception: " ++ show ex
        traceIO $ "Current delay: " ++ show (rsPreviousDelay rs)
        traceIO $ "Total delay: " ++ show (rsCumulativeDelay rs)

-- | The handler for IO exceptions when connecting to sockets.
ioExceptionHandler :: RetryStatus -> Handler IO Bool
ioExceptionHandler = logRetries retryIOException reportIOException

-- | Default retry policy for retrying connections.
connectRetryPolicy :: RetryPolicyM IO
connectRetryPolicy = exponentialBackoff 50 <> limitRetries 20

-- | Retry to connect
retryCnect :: IO a -> IO a
retryCnect act = recovering connectRetryPolicy [ioExceptionHandler] (const act)

-- | Accept byte-streams by serving on the given port number. This function
-- will block until a client connects to the server.
--
-- If the connection cannot be established, this action will be retried using
-- an exponential back-off strategy, until the maximum number of tries is
-- reached.
acceptOn :: PortNumber -> IO Connection
acceptOn p = retryCnect $ do
    addr <- resolvePort p
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    traceIO $ "TextViaSockets: Accepting a connection on port " ++ show p
    setSocketOption sock ReuseAddr 1
    bind sock (addrAddress addr)
    acceptOnSocket sock

-- | Accept byte-streams by serving on the given port number. 
-- This function will start listening, but will not block.
listenOn :: PortNumber -> IO Socket
listenOn p = do
    addr <- resolvePort p
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    traceIO $ "TextViaSockets: Accepting a connection on port " ++ show p
    setSocketOption sock ReuseAddr 1
    bind sock (addrAddress addr)
    listen sock 1 -- Only one queued connection.
    return sock

        
-- | Resolves a portnumber to the SockAddr object needed for many functions from the Network.Socket library
--   Implementation is based on example code from the Network.Socket library.
resolvePort :: PortNumber -> IO AddrInfo
resolvePort port = do
    let hints = defaultHints {
                addrFamily = AF_INET
              , addrSocketType = Stream
              }
    addr:_ <- getAddrInfo (Just hints) Nothing (Just $ show port)
    return addr


-- | Like @acceptOn@ but it takes a bound socket as parameter.
acceptOnSocket :: Socket -> IO Connection
acceptOnSocket sock = retryCnect $ do
    listen sock 1 -- Only one queued connection.
    traceIO $ "TextViaSockets: Accepting connections on socket "
        ++ show sock
    (conn, _) <- accept sock
    pn <- socketPort conn
    traceIO $ "TextViaSockets: Accepted a connection on " ++ show pn
        ++ " (" ++ show conn ++ ")"
    mkConnection conn (Just sock)

-- | Get a free socket from the operating system.
getFreeSocket :: IO Socket
getFreeSocket = retryCnect $ do
    addr <- resolvePort defaultPort
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    setSocketOption sock ReuseAddr 1
    bind sock (addrAddress addr)
    return sock

-- | Connect to the given host and service name (usually a port number).
--
-- If the connection cannot be established, this action will be retried using
-- an exponential back-off strategy, until the maximum number of tries is
-- reached.
connectTo :: HostName -> ServiceName -> IO Connection
connectTo hn sn = do
    sock <-connectToSocket hn sn
    mkConnection sock Nothing


-- | Connect to the given host and service name (usually a port number).
--
-- If the connection cannot be established, this action will be retried using
-- an exponential back-off strategy, until the maximum number of tries is
-- reached.
connectToSocket :: HostName -> ServiceName -> IO Socket
connectToSocket hn sn =  withSocketsDo $ retryCnect $ do
    -- Open the socket.
    traceIO $ "TextViaSockets: Connecting to " ++ show hn' ++ " on " ++ show sn
    addrinfos <- getAddrInfo Nothing (Just hn') (Just sn)
    let svrAddr = head addrinfos
    sock <- socket (addrFamily svrAddr) Stream defaultProtocol
    connect sock (addrAddress svrAddr)
    pn <- socketPort sock
    traceIO $ "TextViaSockets: Connected to " ++ show hn' ++ " on " ++ show pn
        ++ " (" ++ show sock ++ ")"
    return sock
    where
      -- Replace "localhost" to prevent errors on Windows systems where
      -- "localhost" does not resolve to "127.0.0.1"
      hn' = case hn of
          "localhost" -> "127.0.0.1"
          x -> x

mkConnection :: Socket -> Maybe Socket -> IO Connection
mkConnection sock mServerSock = do
    -- Create an empty queue of lines.
    lTQ <- newTQueueIO
    -- Spawn the reader process.
    rTid <- forkIO $ reader lTQ [] (streamDecodeUtf8With lenientDecode)
    return $ Connection sock mServerSock lTQ rTid
    where
      -- | Reads byte-strings from the given socket, decodes the byte-string
      -- into a @Text@ value, and as soon as a new line is found in the text,
      -- the line is placed in the given @TQueue@.
      reader :: TQueue Text -- ^ Transactional queue where to put the text
                            -- lines that are received.
             -> [Text]      -- ^ Text fragments that were received so far,
                            -- where no new lines are found
             -> (ByteString -> Decoding) -- ^ Decoding function. See @Data.Text.Encoding@
             -> IO ()
      reader lTQ acc f = doRead acc f `catch` handler
          where doRead acc' f' = do
                    msg <- recv sock 1024
                    -- Receiving a null byte-string probably means that the
                    -- sending side has closed the connection.
                    unless (B.null msg) $ do
                        let Some text _ g = f' msg
                        rest <- putLines lTQ text acc'
                        doRead rest g
                -- The reader must continue trying to read, even in the
                -- presence of asynchronous exceptions.
                handler :: IOException -> IO ()
                handler _ = do
                    threadDelay $ 5 * 10 ^ (5 :: Int) -- Wait before retrying.
                    return ()
 
      -- | If a new-line is found in @text@, put @text@ together with the
      -- remainder date in @acc@ as one line in @lTQ@. The buffer @acc@ stores
      -- the line fragments as a stack, so it is necessary to reverse this list
      -- before concatenating all the fragments together.
      putLines lTQ text acc =
          if isNothing $ T.find (=='\n') text
              then return (text:acc) -- The text does not contain a new line,
                                     -- so we add it to the front to the
                                     -- fragments list. This means that the
                                     -- text fragments will appear in the
                                     -- reverse order, so it is necessary to
                                     -- reverse the elements when forming the
                                     -- whole line with these fragments.
              else do
              let (suffix, remainder) = T.break (== '\n') text
                  line = T.concat (reverse (suffix:acc)) -- Note that we're
                                                         -- reversing the
                                                         -- buffer here.
              atomically $ writeTQueue lTQ line
              putLines lTQ (T.tail remainder) [] -- We take the tail of the
                                                 -- remaining fragment to
                                                 -- discard the new line
                                                 -- character.

-- | Read a text line from the given connection.
--
-- This function might throw an @BlockedIndefinitelyOnSTM@ exception if the
-- connection to the server is closed, so users of this function should check
-- for this.
getLineFrom :: Connection -> IO Text
getLineFrom Connection {linesTQ} = atomically $ readTQueue linesTQ

-- | Send a list of messages.
sendMsgs :: Connection -> [Text] -> IO ()
sendMsgs conn = traverse_ (putLineTo conn)

-- | Put a text line onto the given connection.
putLineTo :: Connection -> Text -> IO ()
putLineTo Connection {connSock} text = do
    let textEol = T.snoc text '\n'
    sendAll connSock (encodeUtf8 textEol)

-- | Receive `n` messages.
receiveMsgs :: Connection -> Int -> IO [Text]
receiveMsgs conn howMany = replicateM howMany (getLineFrom conn)

-- | Close the connection.
close :: Connection -> IO ()
close Connection{connSock, serverSock, socketReaderTid} = tryClose `catch` handler
    where
      tryClose = do          
          close' connSock
          traceIO $ "TextViaSockets: Closing server socket " ++ show serverSock
          traverse_ close' serverSock
          killThread socketReaderTid
          traceIO "TextViaSockets: Connection closed"
      handler :: IOException -> IO ()
      handler ex = do
          traceIO $ "TextViaSockets: exception while closing the socket: "
              ++ show ex
          throwIO ex

