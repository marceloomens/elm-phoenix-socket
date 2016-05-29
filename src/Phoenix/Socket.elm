module Phoenix.Socket exposing (..)

import Phoenix.Channel as Channel exposing (Channel, setState)
import Phoenix.Push as Push exposing (Push)
import Phoenix.Helpers exposing (Message, messageDecoder, encodeMessage, emptyPayload)
import Dict exposing (Dict)
import WebSocket
import Json.Encode as JE
import Json.Decode as JD exposing ((:=))
import Maybe exposing (andThen)

type alias Socket msg =
  { path : String
  , debug : Bool
  , channels : Dict String (Channel msg)
  , events : Dict ( String, String ) (JE.Value -> msg)
  , pushes : Dict Int (Push msg)
  , ref : Int
  }

type Msg msg
  = NoOp
  | ExternalMsg msg
  | ChannelErrored String
  | ChannelClosed String
  | ChannelJoined String
  | ReceiveReply String Int

init : String -> Socket msg
init path =
  { path = path
  , debug = False
  , channels = Dict.fromList []
  , events = Dict.fromList []
  , pushes = Dict.fromList []
  , ref = 0
  }

update : Msg msg -> Socket msg -> ( Socket msg, Cmd (Msg msg) )
update msg socket =
  case msg of
    ChannelErrored channelName ->
      let
        channels = Dict.update channelName (Maybe.map (setState Channel.Errored)) socket.channels
        socket' = { socket | channels = channels }
      in
        ( socket', Cmd.none )

    ChannelClosed channelName ->
      case Dict.get channelName socket.channels of
        Just channel ->
          let
            channels = Dict.insert channelName (setState Channel.Closed channel) socket.channels
            pushes = Dict.remove channel.joinRef socket.pushes
            socket' = { socket | channels = channels, pushes = pushes }
          in
            ( socket', Cmd.none )

        Nothing ->
          ( socket, Cmd.none )

    ChannelJoined channelName ->
      case Dict.get channelName socket.channels of
        Just channel ->
          let
            channels = Dict.insert channelName (setState Channel.Joined channel) socket.channels
            pushes = Dict.remove channel.joinRef socket.pushes
            socket' = { socket | channels = channels, pushes = pushes }
          in
            ( socket', Cmd.none )

        Nothing ->
          ( socket, Cmd.none )

    _ ->
      ( socket, Cmd.none )

{-| When enabled, prints all incoming Phoenix messages to the console
-}

withDebug : Socket msg -> Socket msg
withDebug socket =
  { socket | debug = True }

join : Channel msg -> Socket msg -> (Socket msg, Cmd (Msg msg))
join channel socket =
  if channel.state == Channel.Leaving then
    ( socket, Cmd.none )
  else
    let
      push' = Push "phx_join" channel.name channel.payload channel.onJoin channel.onError
      channel' = { channel | state = Channel.Joining, joinRef = socket.ref }
      socket' =
        { socket
          | channels = Dict.insert channel.name channel' socket.channels
        }
    in
      push push' socket'

leave : String -> Socket msg -> ( Socket msg, Cmd (Msg msg) )
leave channelName socket =
  case Dict.get channelName socket.channels of
    Just channel ->
      if channel.state == Channel.Joining || channel.state == Channel.Joined then
        let
          push' = Push.init "phx_leave" channel.name
          channel' = { channel | state = Channel.Leaving, leaveRef = socket.ref }
          socket' = { socket | channels = Dict.insert channelName channel' socket.channels }
        in
          push push' socket'
      else
        ( socket, Cmd.none )

    Nothing ->
      ( socket, Cmd.none )

push : Push msg -> Socket msg -> (Socket msg, Cmd (Msg msg))
push push' socket =
  ( { socket
      | pushes = Dict.insert socket.ref push' socket.pushes
      , ref = socket.ref + 1
    }
  , send socket push'.event push'.channel push'.payload
  )


on : String -> String -> (JE.Value -> msg) -> Socket msg -> Socket msg
on eventName channelName onReceive socket =
  { socket
    | events = Dict.insert ( eventName, channelName ) onReceive socket.events
  }

off : String -> String -> Socket msg -> Socket msg
off eventName channelName socket =
  { socket
    | events = Dict.remove ( eventName, channelName ) socket.events
  }

send : Socket msg -> String -> String -> JE.Value -> Cmd (Msg msg)
send {path,ref} event channel payload =
  sendMessage path (Message event channel payload (Just ref))

sendMessage : String -> Message -> Cmd (Msg msg)
sendMessage path message =
  WebSocket.send path (encodeMessage message)



-- SUBSCRIPTIONS

listen : (Msg msg -> msg) -> Socket msg -> Sub msg
listen fn socket =
  (Sub.batch >> Sub.map (mapAll fn))
    [ internalMsgs socket
    , externalMsgs socket
    ]

mapAll : (Msg msg -> msg) -> Msg msg -> msg
mapAll fn internalMsg =
  case internalMsg of
    ExternalMsg msg ->
      msg
    _ ->
      fn internalMsg

phoenixMessages : Socket msg -> Sub (Maybe Message)
phoenixMessages socket =
  WebSocket.listen socket.path (debugIfEnabled socket >> decodeMessage)

debugIfEnabled : Socket msg -> String -> String
debugIfEnabled socket =
  if socket.debug then
    Debug.log "phx_message"
  else
    identity

decodeMessage : String -> Maybe Message
decodeMessage =
  JD.decodeString messageDecoder >> Result.toMaybe

internalMsgs : Socket msg -> Sub (Msg msg)
internalMsgs socket =
  Sub.map (mapInternalMsgs socket) (phoenixMessages socket)

mapInternalMsgs : Socket msg -> Maybe Message -> Msg msg
mapInternalMsgs socket maybeMessage =
  case maybeMessage of
    Just message ->
      case message.event of
        "phx_reply" ->
          handleInternalPhxReply socket message

        "phx_error" ->
          ChannelErrored message.topic

        "phx_close" ->
          ChannelClosed message.topic
        _ ->
          NoOp

    Nothing ->
      NoOp

handleInternalPhxReply : Socket msg -> Message -> Msg msg
handleInternalPhxReply socket message =
  let
    msg =
      Result.toMaybe (JD.decodeValue replyDecoder message.payload)
        `andThen` \(status, response) -> message.ref
        `andThen` \ref -> Dict.get message.topic socket.channels
        `andThen` \channel ->
          if status == "ok" then
            if ref == channel.joinRef then
              Just (ChannelJoined message.topic)
            else if ref == channel.leaveRef then
              Just (ChannelClosed message.topic)
            else
              Nothing
          else
            Nothing
  in
    Maybe.withDefault NoOp msg

externalMsgs : Socket msg -> Sub (Msg msg)
externalMsgs socket =
  Sub.map (mapExternalMsgs socket) (phoenixMessages socket)

mapExternalMsgs : Socket msg -> Maybe Message -> Msg msg
mapExternalMsgs socket maybeMessage =
  case maybeMessage of
    Just message ->
      case message.event of
        "phx_reply" ->
          handlePhxReply socket message
        "phx_error" ->
          let
            channel = Dict.get message.topic socket.channels
            onError = channel `andThen` .onError
            msg = Maybe.map (\f -> (ExternalMsg << f) message.payload) onError
          in
            Maybe.withDefault NoOp msg

        "phx_close" ->
          let
            channel = Dict.get message.topic socket.channels
            onClose = channel `andThen` .onClose
            msg = Maybe.map (\f -> (ExternalMsg << f) message.payload) onClose
          in
            Maybe.withDefault NoOp msg
        _ ->
          handleEvent socket message

    Nothing ->
      NoOp

replyDecoder : JD.Decoder (String, JD.Value)
replyDecoder =
  JD.object2 (,)
    ("status" := JD.string)
    ("response" := JD.value)

handlePhxReply : Socket msg -> Message -> Msg msg
handlePhxReply socket message =
  let
    msg =  
      Result.toMaybe (JD.decodeValue replyDecoder message.payload)
        `andThen` \(status, response) -> message.ref
        `andThen` \ref -> Dict.get ref socket.pushes
        `andThen` \push ->
          case status of
            "ok" ->
              Maybe.map (\f -> (ExternalMsg << f) response) push.onOk
            "error" ->
              Maybe.map (\f -> (ExternalMsg << f) response) push.onError
            _ ->
              Nothing
  in
    Maybe.withDefault NoOp msg

handleEvent : Socket msg -> Message -> Msg msg
handleEvent socket message =
  case Dict.get ( message.event, message.topic ) socket.events of
    Just payloadToMsg ->
      ExternalMsg (payloadToMsg message.payload)

    Nothing ->
      NoOp