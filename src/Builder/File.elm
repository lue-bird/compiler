module Builder.File exposing
    ( Time(..)
    , exists
    , getTime
    , readBinary
    , readUtf8
    , remove
    , timeCodec
    , timeDecoder
    , timeEncoder
    , writeBinary
    , writeBuilder
    , writePackage
    , writeUtf8
    , zeroTime
    )

import Data.IO as IO exposing (IO)
import Json.Decode as Decode
import Json.Encode as Encode
import Serialize exposing (Codec)
import Time
import Utils.Main as Utils exposing (FilePath, ZipArchive, ZipEntry)



-- TIME


type Time
    = Time Time.Posix


getTime : FilePath -> IO Time
getTime path =
    IO.fmap Time (Utils.dirGetModificationTime path)


zeroTime : Time
zeroTime =
    Time (Time.millisToPosix 0)



-- BINARY


writeBinary : Codec e a -> FilePath -> a -> IO ()
writeBinary codec path value =
    let
        dir : FilePath
        dir =
            Utils.fpDropFileName path
    in
    Utils.dirCreateDirectoryIfMissing True dir
        |> IO.bind (\_ -> Utils.binaryEncodeFile codec path value)


readBinary : Codec e a -> FilePath -> IO (Maybe a)
readBinary codec path =
    Utils.dirDoesFileExist path
        |> IO.bind
            (\pathExists ->
                if pathExists then
                    Utils.binaryDecodeFileOrFail codec path
                        |> IO.bind
                            (\result ->
                                case result of
                                    Ok a ->
                                        IO.pure (Just a)

                                    Err ( offset, message ) ->
                                        IO.hPutStrLn IO.stderr
                                            (Utils.unlines
                                                [ "+-------------------------------------------------------------------------------"
                                                , "|  Corrupt File: " ++ path
                                                , "|   Byte Offset: " ++ String.fromInt offset
                                                , "|       Message: " ++ message
                                                , "|"
                                                , "| Please report this to https://github.com/elm/compiler/issues"
                                                , "| Trying to continue anyway."
                                                , "+-------------------------------------------------------------------------------"
                                                ]
                                            )
                                            |> IO.fmap (\_ -> Nothing)
                            )

                else
                    IO.pure Nothing
            )



-- WRITE UTF-8


writeUtf8 : FilePath -> String -> IO ()
writeUtf8 path content =
    IO.make (Decode.succeed ()) (IO.WriteString path content)



-- READ UTF-8


readUtf8 : FilePath -> IO String
readUtf8 path =
    IO.make Decode.string (IO.Read path)



-- WRITE BUILDER


writeBuilder : FilePath -> String -> IO ()
writeBuilder path builder =
    IO.make (Decode.succeed ()) (IO.WriteString path builder)



-- WRITE PACKAGE


writePackage : FilePath -> ZipArchive -> IO ()
writePackage destination archive =
    case Utils.zipZEntries archive of
        [] ->
            IO.pure ()

        entry :: entries ->
            let
                root : Int
                root =
                    String.length (Utils.zipERelativePath entry)
            in
            Utils.mapM_ (writeEntry destination root) entries


writeEntry : FilePath -> Int -> ZipEntry -> IO ()
writeEntry destination root entry =
    let
        path : String
        path =
            String.dropLeft root (Utils.zipERelativePath entry)
    in
    if
        String.startsWith "src/" path
            || (path == "LICENSE")
            || (path == "README.md")
            || (path == "elm.json")
    then
        if not (String.isEmpty path) && String.endsWith "/" path then
            Utils.dirCreateDirectoryIfMissing True (Utils.fpForwardSlash destination path)

        else
            writeUtf8 (Utils.fpForwardSlash destination path) (Utils.zipFromEntry entry)

    else
        IO.pure ()



-- EXISTS


exists : FilePath -> IO Bool
exists path =
    Utils.dirDoesFileExist path



-- REMOVE FILES


remove : FilePath -> IO ()
remove path =
    Utils.dirDoesFileExist path
        |> IO.bind
            (\exists_ ->
                if exists_ then
                    Utils.dirRemoveFile path

                else
                    IO.pure ()
            )



-- ENCODERS and DECODERS


timeEncoder : Time -> Encode.Value
timeEncoder (Time posix) =
    Encode.int (Time.posixToMillis posix)


timeDecoder : Decode.Decoder Time
timeDecoder =
    Decode.map (Time << Time.millisToPosix) Decode.int


timeCodec : Codec e Time
timeCodec =
    Serialize.int |> Serialize.map (Time << Time.millisToPosix) (\(Time posix) -> Time.posixToMillis posix)
