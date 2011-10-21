-- |
-- Module    :  Data.XCB.FromXML
-- Copyright :  (c) Antoine Latter 2008
-- License   :  BSD3
--
-- Maintainer:  Antoine Latter <aslatter@gmail.com>
-- Stability :  provisional
-- Portability: portable
--
-- Handls parsing the data structures from XML files.
--
-- In order to support copying events and errors across module
-- boundaries, all modules which may have cross-module event copies and
-- error copies must be parsed at once.
--
-- There is no provision for preserving the event copy and error copy
-- declarations - the copies are handled during parsing.
module Data.XCB.FromXML(fromFiles
                       ,fromStrings
                       ) where

import Data.XCB.Types
import Data.XCB.Utils

import Text.XML.Light

import Data.List as List
import Data.Maybe

import Control.Monad
import Control.Monad.Reader

-- |Process the listed XML files.
-- Any files which fail to parse are silently dropped.
-- Any declaration in an XML file which fail to parse are
-- silently dropped.
fromFiles :: [FilePath] -> IO [XHeader]
fromFiles xs = do
  strings <- sequence $ map readFile xs
  return $ fromStrings strings

-- |Process the strings as if they were XML files.
-- Any files which fail to parse are silently dropped.
-- Any declaration in an XML file which fail to parse are
-- silently dropped.
fromStrings :: [String] -> [XHeader]
fromStrings xs =
   let rs = mapAlt fromString xs
       Just headers = runReaderT rs headers
   in headers 

-- The 'Parse' monad.  Provides the name of the
-- current module, and a list of all of the modules.
type Parse = ReaderT ([XHeader],Name) Maybe

-- operations in the 'Parse' monad

localName :: Parse Name
localName = snd `liftM` ask

allModules :: Parse [XHeader]
allModules = fst `liftM` ask

-- a generic function for looking up something from
-- a named XHeader.
--
-- this implements searching both the current module and
-- the xproto module if the name is not specified.
lookupThingy :: ([XDecl] -> Maybe a)
             -> (Maybe Name)
             -> Parse (Maybe a)
lookupThingy f Nothing = do
  lname <- localName
  liftM2 mplus (lookupThingy f $ Just lname)
               (lookupThingy f $ Just "xproto") -- implicit xproto import
lookupThingy f (Just mname) = do
  xs <- allModules
  return $ do
    x <- findXHeader mname xs
    f $ xheader_decls x

-- lookup an event declaration by name.
lookupEvent :: Maybe Name -> Name -> Parse (Maybe EventDetails)
lookupEvent mname evname = flip lookupThingy mname $ \decls ->
                 findEvent evname decls

-- lookup an error declaration by name.
lookupError :: Maybe Name -> Name -> Parse (Maybe ErrorDetails)
lookupError mname ername = flip lookupThingy mname $ \decls ->
                 findError ername decls

findXHeader :: Name -> [XHeader] -> Maybe XHeader
findXHeader name = List.find $ \ x -> xheader_header x == name

findError :: Name -> [XDecl] -> Maybe ErrorDetails
findError pname xs =
      case List.find f xs of
        Nothing -> Nothing
        Just (XError name code elems) -> Just $ ErrorDetails name code elems
        _ -> error "impossible: fatal error in Data.XCB.FromXML.findError"
    where  f (XError name _ _) | name == pname = True
           f _ = False 
                                       
findEvent :: Name -> [XDecl] -> Maybe EventDetails
findEvent pname xs = 
      case List.find f xs of
        Nothing -> Nothing
        Just (XEvent name code elems noseq) ->
            Just $ EventDetails name code elems noseq
        _ -> error "impossible: fatal error in Data.XCB.FromXML.findEvent"
   where f (XEvent name _ _ _) | name == pname = True
         f _ = False 

data EventDetails = EventDetails Name Int [StructElem] (Maybe Bool)
data ErrorDetails = ErrorDetails Name Int [StructElem]

---

-- extract a single XHeader from a single XML document
fromString :: String -> ReaderT [XHeader] Maybe XHeader
fromString str = do
  el@(Element _qname _ats cnt _) <- lift $ parseXMLDoc str
  guard $ el `named` "xcb"
  header <- el `attr` "header"
  let name = el `attr` "extension-name"
      xname = el `attr` "extension-xname"
      maj_ver = el `attr` "major-version" >>= readM
      min_ver = el `attr` "minor-version" >>= readM
      multiword = el `attr` "extension-multiword" >>= readM . ensureUpper
  decls <- withReaderT (\r -> (r,header)) $ extractDecls cnt
  return $ XHeader {xheader_header = header
                   ,xheader_xname = xname
                   ,xheader_name = name
                   ,xheader_multiword = multiword
                   ,xheader_major_version = maj_ver
                   ,xheader_minor_version = min_ver
                   ,xheader_decls = decls
                   }

-- attempts to extract declarations from XML content, discarding failures.
extractDecls :: [Content] -> Parse [XDecl]
extractDecls = mapAlt declFromElem . onlyElems

-- attempt to extract a module declaration from an XML element
declFromElem :: Element -> Parse XDecl
declFromElem el
    | el `named` "request" = xrequest el
    | el `named` "event"   = xevent el
    | el `named` "eventcopy" = xevcopy el
    | el `named` "error" = xerror el
    | el `named` "errorcopy" = xercopy el
    | el `named` "struct" = xstruct el
    | el `named` "union" = xunion el
    | el `named` "xidtype" = xidtype el
    | el `named` "xidunion" = xidunion el
    | el `named` "typedef" = xtypedef el
    | el `named` "enum" = xenum el
    | el `named` "import" = ximport el
    | otherwise = mzero


ximport :: Element -> Parse XDecl
ximport = return . XImport . strContent

xenum :: Element -> Parse XDecl
xenum el = do
  nm <- el `attr` "name"
  fields <- mapAlt enumField $ elChildren el
  guard $ not $ null fields
  return $ XEnum nm fields

enumField :: Element -> Parse EnumElem
enumField el = do
  guard $ el `named` "item"
  name <- el `attr` "name"
  let expr = firstChild el >>= expression
  return $ EnumElem name expr

xrequest :: Element -> Parse XDecl
xrequest el = do
  nm <- el `attr` "name"
  code <- el `attr` "opcode" >>= readM
  fields <- mapAlt structField $ elChildren el
  let reply = getReply el
  return $ XRequest nm code fields reply

getReply :: Element -> Maybe XReply
getReply el = do
  childElem <- unqual "reply" `findChild` el
  let fields = mapMaybe structField $ elChildren childElem
  guard $ not $ null fields
  return fields

xevent :: Element -> Parse XDecl
xevent el = do
  name <- el `attr` "name"
  number <- el `attr` "number" >>= readM
  let noseq = ensureUpper `liftM` (el `attr` "no-sequence-number") >>= readM
  fields <- mapAlt structField $ elChildren el
  guard $ not $ null fields
  return $ XEvent name number fields noseq

xevcopy :: Element -> Parse XDecl
xevcopy el = do
  name <- el `attr` "name"
  number <- el `attr` "number" >>= readM
  ref <- el `attr` "ref"
  -- do we have a qualified ref?
  let (mname,evname) = splitRef ref
  details <- lookupEvent mname evname
  return $ let EventDetails _ _ fields noseq =
                 case details of
                   Nothing ->
                       error $ "Unresolved event: " ++ show mname ++ " " ++ ref
                   Just x -> x  
           in XEvent name number fields noseq

-- we need to do string processing to distinguish qualified from
-- unqualified types.
mkType :: String -> Type
mkType str =
    let (mname, name) = splitRef str
    in case mname of
         Just modifier -> QualType modifier name
         Nothing  -> UnQualType name

splitRef :: Name -> (Maybe Name, Name)
splitRef ref = case split ':' ref of
                 (x,"") -> (Nothing, x)
                 (a, b) -> (Just a, b)

-- |Neither returned string contains the first occurance of the
-- supplied Char.
split :: Char -> String -> (String, String)
split c = go
    where go [] = ([],[])
          go (x:xs) | x == c = ([],xs)
                    | otherwise = 
                        let (lefts, rights) = go xs
                        in (x:lefts,rights)
                 

xerror :: Element -> Parse XDecl
xerror el = do
  name <- el `attr` "name"
  number <- el `attr` "number" >>= readM
  fields <- mapAlt structField $ elChildren el
  guard $ not $ null fields
  return $ XError name number fields


xercopy :: Element -> Parse XDecl
xercopy el = do
  name <- el `attr` "name"
  number <- el `attr` "number" >>= readM
  ref <- el `attr` "ref"
  let (mname, ername) = splitRef ref
  details <- lookupError mname ername
  return $ XError name number $ case details of
               Nothing -> error $ "Unresolved error: " ++ show mname ++ " " ++ ref
               Just (ErrorDetails _ _ x) -> x

xstruct :: Element -> Parse XDecl
xstruct el = do
  name <- el `attr` "name"
  fields <- mapAlt structField $ elChildren el
  guard $ not $ null fields
  return $ XStruct name fields

xunion :: Element -> Parse XDecl
xunion el = do
  name <- el `attr` "name"
  fields <- mapAlt structField $ elChildren el
  guard $ not $ null fields
  return $ XUnion name fields

xidtype :: Element -> Parse XDecl
xidtype el = liftM XidType $ el `attr` "name"

xidunion :: Element -> Parse XDecl
xidunion el = do
  name <- el `attr` "name"
  let types = mapMaybe xidUnionElem $ elChildren el
  guard $ not $ null types
  return $ XidUnion name types

xidUnionElem :: Element -> Maybe XidUnionElem
xidUnionElem el = do
  guard $ el `named` "type"
  return $ XidUnionElem $ mkType $ strContent el

xtypedef :: Element -> Parse XDecl
xtypedef el = do
  oldtyp <- liftM mkType $ el `attr` "oldname"
  newname <- el `attr` "newname"
  return $ XTypeDef newname oldtyp


structField :: MonadPlus m => Element -> m StructElem
structField el
    | el `named` "field" = do
        typ <- liftM mkType $ el `attr` "type"
        let enum = liftM mkType $ el `attr` "enum"
        let mask = liftM mkType $ el `attr` "mask"
        name <- el `attr` "name"
        return $ SField name typ enum mask

    | el `named` "pad" = do
        bytes <- el `attr` "bytes" >>= readM
        return $ Pad bytes

    | el `named` "list" = do
        typ <- liftM mkType $ el `attr` "type"
        name <- el `attr` "name"
        let enum = liftM mkType $ el `attr` "enum"
        let expr = firstChild el >>= expression
        return $ List name typ expr enum

    | el `named` "valueparam" = do
        mask_typ <- liftM mkType $ el `attr` "value-mask-type"
        mask_name <- el `attr` "value-mask-name"
        let mask_pad = el `attr` "value-mask-pad" >>= readM
        list_name <- el `attr` "value-list-name"
        return $ ValueParam mask_typ mask_name mask_pad list_name

    | el `named` "exprfield" = do
        typ <- liftM mkType $ el `attr` "type"
        name <- el `attr` "name"
        expr <- firstChild el >>= expression
        return $ ExprField name typ expr

    | el `named` "reply" = fail "" -- handled separate

    | otherwise = let name = elName el
                  in error $ "I don't know what to do with structelem "
 ++ show name

expression :: MonadPlus m => Element -> m Expression
expression el | el `named` "fieldref"
                    = return $ FieldRef $ strContent el
              | el `named` "value"
                    = Value `liftM` readM (strContent el)
              | el `named` "bit"
                    = Bit `liftM` do
                        n <- readM (strContent el)
                        guard $ n >= 0
                        return n
              | el `named` "op" = do
                    binop <- el `attr` "op" >>= toBinop
                    [exprLhs,exprRhs] <- mapM expression $ elChildren el
                    return $ Op binop exprLhs exprRhs
              | otherwise = do
                    error "Unknown epression name in Data.XCB.FromXML.expression"


toBinop :: MonadPlus m => String -> m Binop
toBinop "+"  = return Add
toBinop "-"  = return Sub
toBinop "*"  = return Mult
toBinop "/"  = return Div
toBinop "&"  = return And
toBinop "&amp;" = return And
toBinop ">>" = return RShift
toBinop _ = mzero




----
----
-- Utility functions
----
----

firstChild :: MonadPlus m => Element -> m Element
firstChild = listToM . elChildren

listToM :: MonadPlus m => [a] -> m a
listToM [] = mzero
listToM (x:_) = return x

named :: Element -> String -> Bool
named (Element qname _ _ _) name | qname == unqual name = True
named _ _ = False

attr :: MonadPlus m => Element -> String -> m String
(Element _ xs _ _) `attr` name = case List.find p xs of
      Just (Attr _ res) -> return res
      _ -> mzero
    where p (Attr qname _) | qname == unqual name = True
          p _ = False

-- adapted from Network.CGI.Protocol
readM :: (MonadPlus m, Read a) => String -> m a
readM = liftM fst . listToM . reads

