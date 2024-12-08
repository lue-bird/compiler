module Compiler.Reporting.Annotation exposing
    ( Located(..)
    , Position(..)
    , Region(..)
    , at
    , locatedCodec
    , locatedDecoder
    , locatedEncoder
    , merge
    , mergeRegions
    , one
    , regionCodec
    , regionDecoder
    , regionEncoder
    , toRegion
    , toValue
    , traverse
    , zero
    )

import Json.Decode as Decode
import Json.Encode as Encode
import Serialize exposing (Codec)
import System.TypeCheck.IO as IO exposing (IO)



-- LOCATED


type Located a
    = At Region a -- PERF see if unpacking region is helpful


traverse : (a -> IO b) -> Located a -> IO (Located b)
traverse func (At region value) =
    IO.fmap (At region) (func value)


toValue : Located a -> a
toValue (At _ value) =
    value


merge : Located a -> Located b -> c -> Located c
merge (At r1 _) (At r2 _) value =
    At (mergeRegions r1 r2) value



-- POSITION


type Position
    = Position Int Int


at : Position -> Position -> a -> Located a
at start end a =
    At (Region start end) a



-- REGION


type Region
    = Region Position Position


toRegion : Located a -> Region
toRegion (At region _) =
    region


mergeRegions : Region -> Region -> Region
mergeRegions (Region start _) (Region _ end) =
    Region start end


zero : Region
zero =
    Region (Position 0 0) (Position 0 0)


one : Region
one =
    Region (Position 1 1) (Position 1 1)



-- ENCODERS and DECODERS


regionEncoder : Region -> Encode.Value
regionEncoder (Region start end) =
    Encode.object
        [ ( "type", Encode.string "Region" )
        , ( "start", positionEncoder start )
        , ( "end", positionEncoder end )
        ]


regionDecoder : Decode.Decoder Region
regionDecoder =
    Decode.map2 Region
        (Decode.field "start" positionDecoder)
        (Decode.field "end" positionDecoder)


regionCodec : Codec e Region
regionCodec =
    Serialize.customType
        (\regionCodecEncoder (Region start end) ->
            regionCodecEncoder start end
        )
        |> Serialize.variant2 Region positionCodec positionCodec
        |> Serialize.finishCustomType


positionEncoder : Position -> Encode.Value
positionEncoder (Position start end) =
    Encode.object
        [ ( "type", Encode.string "Position" )
        , ( "start", Encode.int start )
        , ( "end", Encode.int end )
        ]


positionDecoder : Decode.Decoder Position
positionDecoder =
    Decode.map2 Position
        (Decode.field "start" Decode.int)
        (Decode.field "end" Decode.int)


positionCodec : Codec e Position
positionCodec =
    Serialize.customType
        (\positionCodecEncoder (Position start end) ->
            positionCodecEncoder start end
        )
        |> Serialize.variant2 Position Serialize.int Serialize.int
        |> Serialize.finishCustomType


locatedEncoder : (a -> Encode.Value) -> Located a -> Encode.Value
locatedEncoder encoder (At region value) =
    Encode.object
        [ ( "type", Encode.string "Located" )
        , ( "region", regionEncoder region )
        , ( "value", encoder value )
        ]


locatedDecoder : Decode.Decoder a -> Decode.Decoder (Located a)
locatedDecoder decoder =
    Decode.map2 At
        (Decode.field "region" regionDecoder)
        (Decode.field "value" (Decode.lazy (\_ -> decoder)))


locatedCodec : Codec e a -> Codec e (Located a)
locatedCodec =
    Debug.todo "locatedCodec"
