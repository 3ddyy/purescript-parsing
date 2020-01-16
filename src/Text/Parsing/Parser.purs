module Text.Parsing.Parser
  ( ParseError(..)
  , parseErrorMessage
  , parseErrorPosition
  , ParseState(..)
  , ParserT(..)
  , Parser
  , runParser
  , runParserT
  , hoistParserT
  , mapParserT
  , setConsumed
  , consume
  , unconsume
  , position
  , fail
  , failWithPosition
  ) where

import Prelude

import Control.Alt (class Alt)
import Control.Apply (lift2)
import Control.Lazy (defer, class Lazy)
import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Except (class MonadError, ExceptT(..), runExceptT, mapExceptT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.State (class MonadState, StateT(..), evalStateT, get, gets, put, mapStateT, modify_, runStateT)
import Control.Monad.Trans.Class (class MonadTrans, lift)
import Control.MonadPlus (class Alternative, class MonadZero, class MonadPlus, class Plus)
import Data.Compactable (class Compactable)
import Data.Either (Either(..))
import Data.Filterable (class Filterable)
import Data.Identity (Identity)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap, over)
import Data.Tuple (Tuple(..))
import Text.Parsing.Parser.Pos (Position, initialPos)

-- | A parsing error, consisting of a message and position information.
data ParseError = ParseError String Position

parseErrorMessage :: ParseError -> String
parseErrorMessage (ParseError msg _) = msg

parseErrorPosition :: ParseError -> Position
parseErrorPosition (ParseError _ pos) = pos

instance showParseError :: Show ParseError where
  show (ParseError msg pos) =
    "(ParseError " <> show msg <> " " <> show pos <> ")"

derive instance eqParseError :: Eq ParseError
derive instance ordParseError :: Ord ParseError

-- | Contains the remaining input and current position.
data ParseState s = ParseState s Position Boolean

-- | The Parser monad transformer.
-- |
-- | The first type argument is the stream type. Typically, this is either `String`,
-- | or some sort of token stream.
newtype ParserT s m a = ParserT (ExceptT ParseError (StateT (ParseState s) m) a)

derive instance newtypeParserT :: Newtype (ParserT s m a) _

-- | Apply a parser, keeping only the parsed result.
runParserT :: forall m s a. Monad m => s -> ParserT s m a -> m (Either ParseError a)
runParserT s p = evalStateT (runExceptT (unwrap p)) initialState where
  initialState = ParseState s initialPos false

-- | The `Parser` monad is a synonym for the parser monad transformer applied to the `Identity` monad.
type Parser s = ParserT s Identity

-- | Apply a parser, keeping only the parsed result.
runParser :: forall s a. s -> Parser s a -> Either ParseError a
runParser s = unwrap <<< runParserT s

hoistParserT :: forall s m n a. (m ~> n) -> ParserT s m a -> ParserT s n a
hoistParserT = mapParserT

-- | Change the underlying monad action and data type in a ParserT monad action.
mapParserT :: forall b n s a m.
  (  m (Tuple (Either ParseError a) (ParseState s))
  -> n (Tuple (Either ParseError b) (ParseState s))
  ) -> ParserT s m a -> ParserT s n b
mapParserT = over ParserT <<< mapExceptT <<< mapStateT

instance lazyParserT :: Lazy (ParserT s m a) where
  defer f = ParserT (ExceptT (defer (runExceptT <<< unwrap <<< f)))

instance semigroupParserT :: (Monad m, Semigroup a) => Semigroup (ParserT s m a) where
  append = lift2 (<>)

instance monoidParserT :: (Monad m, Monoid a) => Monoid (ParserT s m a) where
  mempty = pure mempty

derive newtype instance functorParserT :: Functor m => Functor (ParserT s m)
derive newtype instance applyParserT :: Monad m => Apply (ParserT s m)
derive newtype instance applicativeParserT :: Monad m => Applicative (ParserT s m)
derive newtype instance bindParserT :: Monad m => Bind (ParserT s m)
derive newtype instance monadParserT :: Monad m => Monad (ParserT s m)
derive newtype instance monadRecParserT :: MonadRec m => MonadRec (ParserT s m)
derive newtype instance monadStateParserT :: Monad m => MonadState (ParseState s) (ParserT s m)
derive newtype instance monadThrowParserT :: Monad m => MonadThrow ParseError (ParserT s m)
derive newtype instance monadErrorParserT :: Monad m => MonadError ParseError (ParserT s m)

instance altParserT :: Monad m => Alt (ParserT s m) where
  alt p1 p2 = (ParserT <<< ExceptT <<< StateT) \(s@(ParseState i p _)) -> do
    Tuple e s'@(ParseState i' p' c') <- runStateT (runExceptT (unwrap p1)) (ParseState i p false)
    case e of
      Left err
        | not c' -> runStateT (runExceptT (unwrap p2)) s
      _ -> pure (Tuple e s')

instance plusParserT :: Monad m => Plus (ParserT s m) where
  empty = fail "No alternative"

instance alternativeParserT :: Monad m => Alternative (ParserT s m)

instance monadZeroParserT :: Monad m => MonadZero (ParserT s m)

instance monadPlusParserT :: Monad m => MonadPlus (ParserT s m)

instance monadTransParserT :: MonadTrans (ParserT s) where
  lift = ParserT <<< lift <<< lift

instance compactableParserT :: Monad m => Compactable (ParserT s m) where
  compact p1 = do
    state <- get
    p1 >>= case _ of
      Just r -> pure r
      Nothing -> put state *> fail "Parse returned Nothing"
  separate p1 =
    { left: do
      state <- get
      p1 >>= case _ of
        Left r -> pure r
        Right r -> put state *> fail "Parse returned Right"
    , right: do
      state <- get
      p1 >>= case _ of
        Left r -> put state *> fail "Parse returned Left"
        Right r -> pure r
    }

instance filterableParserT :: Monad m => Filterable (ParserT s m) where
  partitionMap pred p1 =
    { left: do
      state <- get
      p1 <#> pred >>= case _ of
        Left r -> pure r
        Right r -> put state *> fail "Predicate returned Right"
    , right: do
      state <- get
      p1 <#> pred >>= case _ of
        Left r -> put state *> fail "Predicate returned Left"
        Right r -> pure r
    }
  partition pred p1 =
    { yes: do
      state <- get
      r <- p1
      case pred r of
        true -> pure r
        false -> put state *> fail "Result did not satisfy predicate"
    , no: do
      state <- get
      r <- p1
      case pred r of
        true -> put state *> fail "Result unexpectedly satisfied predicate"
        false -> pure r
    }
  filterMap pred p1 = do
    state <- get
    p1 <#> pred >>= case _ of
      Just r -> pure r
      Nothing -> put state *> fail "Predicate returned Nothing"
  filter pred p1 = do
    state <- get
    r <- p1
    case pred r of
      true -> pure r
      false -> put state *> fail "Result did not satisfy predicate"


-- | Set or unset the consumed flag.
setConsumed :: forall s m. Monad m => Boolean -> ParserT s m Unit
setConsumed bool = modify_ \(ParseState input pos _) ->
  ParseState input pos bool

-- | Set the consumed flag.
consume :: forall s m. Monad m => ParserT s m Unit
consume = setConsumed true

unconsume :: forall s m. Monad m => ParserT s m Unit
unconsume = setConsumed false

-- | Returns the current position in the stream.
position :: forall s m. Monad m => ParserT s m Position
position = gets \(ParseState _ pos _) -> pos

-- | Fail with a message.
fail :: forall m s a. Monad m => String -> ParserT s m a
fail message = failWithPosition message =<< position

-- | Fail with a message and a position.
failWithPosition :: forall m s a. Monad m => String -> Position -> ParserT s m a
failWithPosition message pos = throwError (ParseError message pos)
