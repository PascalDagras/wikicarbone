module Page.Editorial exposing (..)

import Data.Session exposing (Session)
import Html exposing (..)
import Html.Attributes exposing (..)
import Http
import Markdown
import Request.HttpClient as HttpClient


type Msg
    = ContentReceived (Result Http.Error String)


type State
    = Loading
    | Loaded String
    | Errored Http.Error


type alias Model =
    { slug : String
    , state : State
    }


init : String -> Session -> ( Model, Session, Cmd Msg )
init slug session =
    ( Model slug Loading
    , session
    , HttpClient.getMarkdownFile session (slug ++ ".md") ContentReceived
    )


update : Session -> Msg -> Model -> ( Model, Session, Cmd Msg )
update session msg model =
    case msg of
        ContentReceived (Ok content) ->
            ( { model | state = Loaded content }
            , session
            , Cmd.none
            )

        ContentReceived (Err error) ->
            ( { model | state = Errored error }
            , session
            , Cmd.none
            )


extractTitle : String -> String
extractTitle =
    String.split "\n"
        >> List.head
        >> Maybe.map (String.replace "# " "")
        >> Maybe.withDefault "À propos"


errorToMarkdown : Http.Error -> String
errorToMarkdown error =
    """## Error

There was an error attempting to retrieve README information:

> *""" ++ HttpClient.errorToString error ++ "*"


view : Session -> Model -> ( String, List (Html Msg) )
view _ { state } =
    case state of
        Loading ->
            ( "Chargement…", [ text "loading…" ] )

        Loaded content ->
            ( extractTitle content
            , [ article [ class "row justify-content-center" ]
                    [ content |> Markdown.toHtml [ class "col-md-8 md-content" ] ]
              ]
            )

        Errored error ->
            ( "Erreur", [ text (errorToMarkdown error) ] )
