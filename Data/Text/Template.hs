-- | A simple string substitution library that supports \"$\"-based
-- substitution. Substitution uses the following rules:
--
--    * \"$$\" is an escape; it is replaced with a single \"$\".
--
--    * \"$identifier\" names a substitution placeholder matching a
--      mapping key of \"identifier\". \"identifier\" must spell a
--      Haskell identifier. The first non-identifier character after the
--      \"$\" character terminates this placeholder specification.
--
--    * \"${identifier}\" is equivalent to \"$identifier\". It is
--      required when valid identifier characters follow the placeholder
--      but are not part of the placeholder, such as
--      \"${noun}ification\".
--
-- Any other apperance of \"$\" in the string will result in an
-- 'Prelude.error' being raised.
--
-- If you render the same template multiple times it's faster to first
-- convert it to a more efficient representation using 'template' and
-- then render it using 'render'. In fact, all that 'substitute' does
-- is to combine these two steps.

module Data.Text.Template
    (
     -- * The @Template@ type
     Template,

     -- * The @Context@ type
     Context,

     -- * Basic interface
     template,
     render,
     substitute,
     showTemplate,

     -- * Example
     -- $example
    ) where

import Control.Monad (liftM, liftM2)
import Control.Monad.State (State, evalState, get, put)
import Data.Char (isAlphaNum)
import Data.Map (Map)
import Prelude hiding (takeWhile)

import qualified Data.Map as Map
import qualified Data.Text as T

-- -----------------------------------------------------------------------------

-- | A repesentation of a 'Data.Text' template, supporting efficient
-- rendering.
newtype Template = Template [Frag]

instance Eq Template where
    t1 == t2 = showTemplate t1 == showTemplate t2

instance Show Template where
    show = T.unpack . showTemplate

-- | Shows the template string.
showTemplate :: Template -> T.Text
showTemplate (Template fs) = T.concat $ map showFrag fs

-- | A template fragment.
data Frag = Lit !T.Text | Var !T.Text !Bool

instance Show Frag where
    show = T.unpack . showFrag

showFrag :: Frag -> T.Text
showFrag (Var s b)
    | b          = T.concat [T.pack "${", s, T.pack "}"]
    | otherwise  = T.concat [T.pack "$", s]
showFrag (Lit s) = T.concatMap escape s
    where escape '$' = T.pack "$$"
          escape c   = T.singleton c

-- | A mapping with keys that match the placeholders in the template.
type Context = Map T.Text T.Text

-- -----------------------------------------------------------------------------
-- Basic interface

-- | Creates a template from a template string.
template :: T.Text -> Template
template = runParser pTemplate

-- | Performs the template substitution, returning a new 'Data.Text'.
--
-- If a key is not found in the context an 'Prelude.error' is raised.
render :: Template -> Context -> T.Text
render (Template frags) ctx = T.concat $ map renderFrag frags
  where
    renderFrag (Lit s)   = s
    renderFrag (Var x _) = maybe keyError id (Map.lookup x ctx)
      where keyError = error $ "Key not found: " ++ (show $ T.unpack x)

-- | Performs the template substitution, returning a new
-- 'Data.Text'. Note that
--
-- > substitute tmpl ctx == render (template tmpl) ctx
--
-- If a key is not found in the context an 'Prelude.error' is raised.
substitute :: T.Text -> Context -> T.Text
substitute = render . template

-- -----------------------------------------------------------------------------
-- Template parser

pTemplate :: Parser Template
pTemplate = fmap Template pFrags

pFrags :: Parser [Frag]
pFrags = do
    c <- peek
    case c of
        Nothing  -> return []
        Just '$' -> do c' <- peekSnd
                       case c' of
                           Just '$' -> do Just '$' <- char
                                          Just '$' <- char
                                          continue (return $ Lit $ T.pack "$")
                           _        -> continue pVar
        _        -> continue pLit
  where
    continue x = liftM2 (:) x pFrags

pLit :: Parser Frag
pLit = do
    s <- takeWhile (/= '$')
    return $ Lit s

pVar :: Parser Frag
pVar = do
    Just '$' <- char
    c <- peek
    case c of
        Just '{' -> do Just '{' <- char
                       v <- pIdentifier
                       c' <- peek
                       case c' of
                         Just '}' -> do Just '}' <- char
                                        return $ Var v True
                         _        -> liftM parseError pos
        _        -> do v <- pIdentifier
                       return $ Var v False

pIdentifier :: Parser T.Text
pIdentifier = do
    c <- peek
    case c of
      Just c'
          | isAlphaNum c' -> takeWhile isIdentifier
          | otherwise     -> liftM parseError pos
      Nothing             -> liftM parseError pos
  where
    isIdentifier c = or [isAlphaNum c, c `elem` "_'"]

parseError :: (Int, Int) -> a
parseError (row, col) = error $ "Invalid placeholder in string: line " ++
                        show row ++ ", col " ++ show col

-- -----------------------------------------------------------------------------
-- Text parser

type Parser = State (T.Text, Int, Int)

char :: Parser (Maybe Char)
char = do
    (s, row, col) <- get
    if T.null s
      then return Nothing
      else do c <- return $! T.head s
              case c of
                '\n' -> put (T.tail s, row + 1 :: Int, 1 :: Int)
                _    -> put (T.tail s, row, col + 1 :: Int)
              return $ Just c

peek :: Parser (Maybe Char)
peek = do
    s <- get
    c <- char
    put s
    return c

peekSnd :: Parser (Maybe Char)
peekSnd = do
    s <- get
    char
    c <- char
    put s
    return c

takeWhile :: (Char -> Bool) -> Parser T.Text
takeWhile p = do
    (s, row, col) <- get
    case T.span p s of
      (x, s') -> do
                  let newlines = T.elemIndices '\n' x
                      n = T.length x
                      row' = row + fromIntegral (length newlines)
                      col' = case newlines of
                               [] -> col + n
                               _  -> n - last newlines
                  put (s', row', col')
                  return x

pos :: Parser (Int, Int)
pos = do
    (_, row, col) <- get
    return (row, col)

runParser :: Parser a -> T.Text -> a
runParser p s = evalState p (s, 1 :: Int, 1 :: Int)

-- -----------------------------------------------------------------------------
-- Example

-- $example
--
-- Here is an example of a simple substitution:
--
-- > module Main where
-- >
-- > import qualified Data.ByteString as S
-- > import qualified Data.Map as M
-- > import qualified Data.Text as T
-- > import qualified Data.Text.Encoding as E
-- >
-- > import Data.Text.Template
-- >
-- > -- | Create 'Context' from association list.
-- > context :: [(String, String)] -> M.Map T.Text T.Text
-- > context = M.fromList . map packPair
-- >     where packPair (x, y) = (T.pack x, T.pack y)
-- >
-- > main :: IO ()
-- > main = S.putStr $ E.encodeUtf8 $ substitute helloTemplate helloContext
-- >   where
-- >     helloTemplate = T.pack "Hello, $name!\n"
-- >     helloContext  = context [("name", "Joe")]
--
-- The example can be simplified by using the 'OverloadedStrings'
-- language extension:
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- >
-- > module Main where
-- >
-- > import qualified Data.ByteString as S
-- > import qualified Data.Map as M
-- > import qualified Data.Text.Encoding as E
-- >
-- > import Data.Text.Template
-- >
-- > main :: IO ()
-- > main = S.putStr $ E.encodeUtf8 $ substitute helloTemplate helloContext
-- >   where
-- >     helloTemplate = "Hello, $name!\n"
-- >     helloContext  = M.fromList [("name", "Joe")]