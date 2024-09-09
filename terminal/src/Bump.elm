module Bump exposing (run)

import BackgroundWriter as BW
import Build
import Data.IO as IO exposing (IO)
import Data.NonEmptyList as NE
import Deps.Bump as Bump
import Deps.Diff as Diff
import Deps.Registry as Registry
import Elm.Details as Details
import Elm.Docs as Docs
import Elm.Magnitude as M
import Elm.Outline as Outline
import Elm.Version as V
import Http
import Reporting
import Reporting.Doc as D
import Reporting.Exit as Exit
import Reporting.Exit.Help as Help
import Reporting.Task as Task
import Stuff
import Utils exposing (FilePath)



-- RUN


run : () -> () -> IO ()
run () () =
    Reporting.attempt Exit.bumpToReport <|
        Task.run (Task.bind bump getEnv)



-- ENV


type Env
    = Env FilePath Stuff.PackageCache Http.Manager Registry.Registry Outline.PkgOutline


getEnv : Task.Task Exit.Bump Env
getEnv =
    Task.io Stuff.findRoot
        |> Task.bind
            (\maybeRoot ->
                case maybeRoot of
                    Nothing ->
                        Task.throw Exit.BumpNoOutline

                    Just root ->
                        Task.io Stuff.getPackageCache
                            |> Task.bind
                                (\cache ->
                                    Task.io Http.getManager
                                        |> Task.bind
                                            (\manager ->
                                                Task.eio Exit.BumpMustHaveLatestRegistry (Registry.latest manager cache)
                                                    |> Task.bind
                                                        (\registry ->
                                                            Task.eio Exit.BumpBadOutline (Outline.read root)
                                                                |> Task.bind
                                                                    (\outline ->
                                                                        case outline of
                                                                            Outline.App _ ->
                                                                                Task.throw Exit.BumpApplication

                                                                            Outline.Pkg pkgOutline ->
                                                                                Task.pure (Env root cache manager registry pkgOutline)
                                                                    )
                                                        )
                                            )
                                )
            )



-- BUMP


bump : Env -> Task.Task Exit.Bump ()
bump ((Env root _ _ registry ((Outline.PkgOutline pkg _ _ vsn _ _ _ _) as outline)) as env) =
    case Registry.getVersions pkg registry of
        Just knownVersions ->
            let
                bumpableVersions =
                    List.map (\( old, _, _ ) -> old) (Bump.getPossibilities knownVersions)
            in
            if List.member vsn bumpableVersions then
                suggestVersion env

            else
                Task.throw <|
                    Exit.BumpUnexpectedVersion vsn <|
                        List.map Utils.head (Utils.listGroupBy (==) (List.sortWith V.compare bumpableVersions))

        Nothing ->
            Task.io <| checkNewPackage root outline



-- CHECK NEW PACKAGE


checkNewPackage : FilePath -> Outline.PkgOutline -> IO ()
checkNewPackage root ((Outline.PkgOutline _ _ _ version _ _ _ _) as outline) =
    Utils.putStrLn Exit.newPackageOverview
        |> IO.bind
            (\_ ->
                if version == V.one then
                    Utils.putStrLn "The version number in elm.json is correct so you are all set!"

                else
                    changeVersion root outline V.one <|
                        (D.fromChars "It looks like the version in elm.json has been changed though!\nWould you like me to change it back to "
                            |> D.a (D.fromVersion V.one)
                            |> D.a (D.fromChars "? [Y/n] ")
                        )
            )



-- SUGGEST VERSION


suggestVersion : Env -> Task.Task Exit.Bump ()
suggestVersion (Env root cache manager _ ((Outline.PkgOutline pkg _ _ vsn _ _ _ _) as outline)) =
    Task.eio (Exit.BumpCannotFindDocs pkg vsn) (Diff.getDocs cache manager pkg vsn)
        |> Task.bind
            (\oldDocs ->
                generateDocs root outline
                    |> Task.bind
                        (\newDocs ->
                            let
                                changes =
                                    Diff.diff oldDocs newDocs

                                newVersion =
                                    Diff.bump changes vsn

                                old =
                                    D.fromVersion vsn

                                new =
                                    D.fromVersion newVersion

                                mag =
                                    D.fromChars <| M.toChars (Diff.toMagnitude changes)
                            in
                            Task.io <|
                                changeVersion root outline newVersion <|
                                    (D.fromChars "Based on your new API, this should be a"
                                        |> D.plus (D.green mag)
                                        |> D.plus (D.fromChars "change (")
                                        |> D.a old
                                        |> D.a (D.fromChars " => ")
                                        |> D.a new
                                        |> D.a (D.fromChars ")\n")
                                        |> D.a (D.fromChars "Bail out of this command and run 'elm diff' for a full explanation.\n")
                                        |> D.a (D.fromChars "\n")
                                        |> D.a (D.fromChars "Should I perform the update (")
                                        |> D.a old
                                        |> D.a (D.fromChars " => ")
                                        |> D.a new
                                        |> D.a (D.fromChars ") in elm.json? [Y/n] ")
                                    )
                        )
            )


generateDocs : FilePath -> Outline.PkgOutline -> Task.Task Exit.Bump Docs.Documentation
generateDocs root (Outline.PkgOutline _ _ _ _ exposed _ _ _) =
    Task.eio Exit.BumpBadDetails
        (BW.withScope
            (\scope ->
                Details.load Reporting.silent scope root
            )
        )
        |> Task.bind
            (\details ->
                case Outline.flattenExposed exposed of
                    [] ->
                        Task.throw <| Exit.BumpNoExposed

                    e :: es ->
                        Task.eio Exit.BumpBadBuild <|
                            Build.fromExposed Reporting.silent root details Build.KeepDocs (NE.Nonempty e es)
            )



-- CHANGE VERSION


changeVersion : FilePath -> Outline.PkgOutline -> V.Version -> D.Doc -> IO ()
changeVersion root (Outline.PkgOutline name summary license _ exposed deps testDeps elmVersion) targetVersion question =
    Reporting.ask question
        |> IO.bind
            (\approved ->
                if not approved then
                    Utils.putStrLn "Okay, I did not change anything!"

                else
                    Outline.write root
                        (Outline.Pkg
                            (Outline.PkgOutline name summary license targetVersion exposed deps testDeps elmVersion)
                        )
                        |> IO.bind
                            (\_ ->
                                Help.toStdout
                                    (D.fromChars "Version changed to "
                                        |> D.a (D.green (D.fromVersion targetVersion))
                                        |> D.a (D.fromChars "!\n")
                                    )
                            )
            )