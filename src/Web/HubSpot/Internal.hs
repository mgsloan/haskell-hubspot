module Web.HubSpot.Internal where

--------------------------------------------------------------------------------

import Web.HubSpot.Common
import qualified Data.ByteString.Lazy as BL
import Data.HashMap.Strict (HashMap)
import Data.Hashable (Hashable)
import qualified Data.Text as TS
import qualified Data.Text.Encoding as TS

--------------------------------------------------------------------------------

-- | Client ID
--
-- Note: Use the 'IsString' instance (e.g. with @OverloadedStrings@) for easy
-- construction.
newtype ClientId = ClientId { fromClientId :: ByteString }
  deriving IsString

instance Show ClientId where
  show = showBS . fromClientId

instance ToJSON ClientId where
  toJSON = String . TS.decodeUtf8 . fromClientId

instance FromJSON ClientId where
  parseJSON = fmap (ClientId . TS.encodeUtf8) . parseJSON

--------------------------------------------------------------------------------

-- | Portal ID (sometimes called Hub ID or account number)
--
-- Note: Use the 'Num' instance for easy construction.
newtype PortalId = PortalId { fromPortalId :: Int }
  deriving Num

instance Read PortalId where
  readsPrec n = map (first PortalId) . readsPrec n

instance Show PortalId where
  show = show . fromPortalId

instance ToJSON PortalId where
  toJSON = toJSON . fromPortalId

instance FromJSON PortalId where
  parseJSON = fmap PortalId . parseJSON

portalIdQueryVal :: PortalId -> ByteString
portalIdQueryVal = intToBS . fromPortalId

-- | An unexported, intermediate type used in refreshAuth
newtype AuthPortalId = AuthPortalId { portal_id :: PortalId }

--------------------------------------------------------------------------------

-- | An OAuth scope from https://developers.hubspot.com/auth/oauth_scopes
type Scope = ByteString

--------------------------------------------------------------------------------

-- | Authentication information
data Auth = Auth
  { authAccessToken  :: ByteString       -- ^ Access token
  , authRefreshToken :: Maybe ByteString -- ^ Refresh token for "offline" scope
  , authExpiresIn    :: UTCTime          -- ^ Expiration time of of the access token
  }
  deriving Show

instance ToJSON Auth where
  toJSON (Auth {..}) = object
    [ "access_token"  .= (String . TS.decodeUtf8 $ authAccessToken)
    , "refresh_token" .= (String . TS.decodeUtf8 <$> authRefreshToken)
    , "expires_in"    .= authExpiresIn
    ]

instance FromJSON Auth where
  parseJSON = withObject "Auth" $ \o -> do
    Auth <$> (TS.encodeUtf8 <$> o .: "access_token")
         <*> (fmap TS.encodeUtf8 <$> o .: "refresh_token")
         <*> o .: "expires_in"

expireTime :: UTCTime -> Int -> UTCTime
expireTime tm sec = fromIntegral sec `addUTCTime` tm

mkAuth :: MonadIO m => (ByteString, Maybe ByteString, Int) -> m Auth
mkAuth (at,rt,sec) = do
  tm <- liftIO getCurrentTime
  return $ Auth at rt $ expireTime tm sec

pAuth :: Monad m => UTCTime -> Object -> m Auth
pAuth tm = either (fail . mappend "pAuth") return . parseEither (\o ->
  Auth <$> (TS.encodeUtf8 <$> o .: "access_token")
       <*> (Just . TS.encodeUtf8 <$> o .: "refresh_token")
       <*> (expireTime tm <$> o .: "expires_in"))

mkAuthFromResponse :: MonadIO m => Response BL.ByteString -> m (Auth, PortalId)
mkAuthFromResponse rsp = do
  tm <- liftIO getCurrentTime
  (,) `liftM` (jsonContent "Auth" rsp >>= pAuth tm)
      `ap`    (portal_id `liftM` jsonContent "PortalId" rsp)

newAuthReq :: MonadIO m => Auth -> [Text] -> m Request
newAuthReq Auth {..} pieces = parseUrl (TS.unpack $ TS.intercalate "/" pieces)
  >>= setQuery [("access_token", Just authAccessToken)]

--------------------------------------------------------------------------------

-- | Error message JSON object returned by HubSpot
data ErrorMessage = ErrorMessage
  { errorMessage   :: !Text
  , errorRequestId :: !Text
  }
  deriving Show

instance ToJSON ErrorMessage where
  toJSON ErrorMessage {..} = object
    [ "status"    .= String "error"
    , "message"   .= String errorMessage
    , "requestId" .= String errorRequestId
    ]

instance FromJSON ErrorMessage where
  parseJSON = withObject "ErrorMessage" $ \o -> do
    ErrorMessage <$> o .: "message"
                 <*> o .: "requestId"

--------------------------------------------------------------------------------

-- | Contact ID (sometimes called visitor ID or vid)
--
-- Note: Use the 'Num' instance for easy construction.
newtype ContactId = ContactId { fromContactId :: Int }
  deriving (Eq, Num, Hashable)

instance Read ContactId where
  readsPrec n = map (first ContactId) . readsPrec n

instance Show ContactId where
  show = show . fromContactId

instance ToJSON ContactId where
  toJSON = toJSON . fromContactId

instance FromJSON ContactId where
  parseJSON = fmap ContactId . parseJSON

--------------------------------------------------------------------------------

-- | Contact User Token (sometimes called HubSpot cookie or hubspotutk)
--
-- Note: Use the 'IsString' instance (e.g. with @OverloadedStrings@) for easy
-- construction.
newtype UserToken = UserToken { fromUserToken :: ByteString }
  deriving IsString

instance Show UserToken where
  show = showBS . fromUserToken

--------------------------------------------------------------------------------

-- | A contact profile from HubSpot
--
-- Note: This is a simple type synonym. We should use a real data type.
type Contact = HashMap Text Value

-- | An unexported, intermediate type used in getContacts
data ContactsPage = ContactsPage
  { contacts   :: ![Contact]
  , has_more   :: !Bool
  , vid_offset :: !Int
  }

tuplePage :: ContactsPage -> ([Contact], Bool, Int)
tuplePage (ContactsPage a b c) = (a, b, c)

--------------------------------------------------------------------------------

-- | This represents a contact property (or field) object.
--
-- Ideally, we would use only enumerations for the values of 'propType' and
-- 'propFieldType'. However, we have observed unexpected strings from HubSpot, and
-- we use 'Left' for these values.
--
-- https://developers.hubspot.com/docs/methods/contacts/create_property
data Property = Property
  { propName          :: !Text
  , propLabel         :: !Text
  , propDescription   :: !Text
  , propGroupName     :: !Text
  , propType          :: !(Either Text PropertyType)
  , propFieldType     :: !(Either Text PropertyFieldType)
  , propFormField     :: !Bool
  , propDisplayOrder  :: !Int
  , propOptions       :: ![PropertyOption]
  }
  deriving Show

instance ToJSON Property where
  toJSON Property {..} = object
    [ "name"         .= propName
    , "label"        .= propLabel
    , "description"  .= propDescription
    , "groupName"    .= propGroupName
    , "type"         .= eitherToJSON propType
    , "fieldType"    .= eitherToJSON propFieldType
    , "formField"    .= propFormField
    , "displayOrder" .= propDisplayOrder
    , "options"      .= propOptions
    ]

instance FromJSON Property where
  parseJSON = withObject "Property" $ \o -> do
    Property <$> o .:  "name"
             <*> o .:  "label"
             <*> o .:  "description"
             <*> o .:  "groupName"
             <*> o .:^ "type"
             <*> o .:^ "fieldType"
             <*> o .:  "formField"
             <*> o .:  "displayOrder"
             <*> o .:  "options"

data PropertyType
  = PTString
  | PTNumber
  | PTBool
  | PTDateTime
  | PTEnumeration
  deriving (Eq, Enum, Bounded, Read, Show)

data PropertyFieldType
  = PFTTextArea
  | PFTSelect
  | PFTText
  | PFTDate
  | PFTFile
  | PFTNumber
  | PFTRadio
  | PFTCheckBox
  deriving (Eq, Enum, Bounded, Read, Show)

data PropertyOption = PropertyOption
  { poLabel        :: !Text
  , poValue        :: !Text
  , poDisplayOrder :: !Int
  }
  deriving Show

--------------------------------------------------------------------------------

-- | This is used to set the value of a property on a contact.
data PropertyValue = PropertyValue
  { pvName  :: !Text
  , pvValue :: !Text
  }

instance ToJSON PropertyValue where
  toJSON PropertyValue {..} = object
    [ "property" .= pvName
    , "value"    .= pvValue
    ]

instance FromJSON PropertyValue where
  parseJSON = withObject "PropertyValue" $ \o -> do
    PropertyValue <$> o .: "property"
                  <*> o .: "value"

-- | An unexported, intermediate type used for retrieving a list of
-- 'PropertyValue's.
data PropValueList = PropValueList { pvlProperties  :: ![PropertyValue] }

--------------------------------------------------------------------------------

-- | A property group.
--
-- In some cases, the group object returned from HubSpot does not have a
-- @properties@ field. Instead of using a separate type for those cases, we
-- simply return a 'Group' value with an empty 'groupProperties' list.
--
-- https://developers.hubspot.com/docs/methods/contacts/create_group
data Group = Group
  { groupName         :: !Text
  , groupDisplayName  :: !Text
  , groupDisplayOrder :: !Int
  , groupPortalId     :: !PortalId
  , groupProperties   :: ![Property] -- ^ This list is empty if no properties field is available.
  }
  deriving Show

instance ToJSON Group where
  toJSON Group {..} = object $
    [ "name"         .= groupName
    , "displayName"  .= groupDisplayName
    , "displayOrder" .= groupDisplayOrder
    , "portalId"     .= groupPortalId
    ] ++
    (pairIf (not . null) "properties" groupProperties) -- Only included if not empty

instance FromJSON Group where
  parseJSON = withObject "Group" $ \o -> do
    Group <$> o .:  "name"
          <*> o .:  "displayName"
          <*> o .:  "displayOrder"
          <*> o .:  "portalId"
          <*> o .:* "properties"  -- Empty if not found

--------------------------------------------------------------------------------
-- Template Haskell declarations go at the end.

deriveJSON_ ''AuthPortalId      defaultOptions

deriveJSON_ ''PropertyType      (defaultEnumOptions   2)
deriveJSON_ ''PropertyFieldType (defaultEnumOptions   3)

deriveJSON_ ''PropertyOption    (defaultRecordOptions 2)
deriveJSON_ ''PropValueList     (defaultRecordOptions 3)

deriveJSON_ ''ContactsPage
  defaultOptions { fieldLabelModifier = map (\c -> if c == '_' then '-' else c) }
