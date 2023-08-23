import Foundation
import XMTP

// Wrapper around XMTP.DecodedMessage to allow passing these objects back
// into react native.
struct DecodedMessageWrapper {
    static func encodeToObj(_ model: XMTP.DecodedMessage, topic: String) throws -> [String: Any] {
        return [
            "id": model.id,
            "topic": topic,
            "contentTypeId": model.encodedContent.type.id,
            "content": try ContentJson.fromEncoded(model.encodedContent).toJsonMap() as Any,
            "senderAddress": model.senderAddress,
            "sent": UInt64(model.sent.timeIntervalSince1970 * 1000)
        ]
    }

    static func encode(_ model: XMTP.DecodedMessage, topic: String) throws -> String {
        let obj = try encodeToObj(model, topic: topic)
        return try obj.toJson()
    }
}

// NOTE: cribbed from xmtp-ios to make visible here.
extension ContentTypeID {
    var id: String {
        "\(authorityID):\(typeID)"
    }
}

struct ContentJson {
    var type: ContentTypeID
    var content: Any

    static var codecs: [any ContentCodec] = [
        TextCodec(),
        ReactionCodec(),
        AttachmentCodec(),
        ReplyCodec(),
        RemoteAttachmentCodec()
        // TODO:
        //CompositeCodec(),
    ]

    static func initCodecs() -> Void {
        codecs.forEach { codec in Client.register(codec: codec) }
    }

    enum Error: Swift.Error {
        case unknownContentType, badAttachmentData, badReplyContent, badRemoteAttachmentMetadata
    }

    static func fromEncoded(_ encoded: XMTP.EncodedContent) throws -> ContentJson {
        return ContentJson(type: encoded.type, content: try encoded.decoded())
    }

    static func fromJsonObj(_ obj: [String: Any]) throws -> ContentJson {
        if let text = obj["text"] as? String {
            return ContentJson(type: ContentTypeText, content: text)
        } else if let reaction = obj["reaction"] as? [String: Any] {
            return ContentJson(type: ContentTypeReaction, content: Reaction(
                    reference: reaction["reference"] as? String ?? "",
                    action: ReactionAction(rawValue: reaction["action"] as? String ?? "") ?? .added,
                    content: reaction["content"] as? String ?? "",
                    schema: ReactionSchema(rawValue: reaction["schema"] as? String ?? "") ?? .unicode
            ))
        } else if let reply = obj["reply"] as? [String: Any] {
            guard let nestedContent = reply["content"] as? [String: Any] else {
                throw Error.badReplyContent
            }
            guard let nested = try? fromJsonObj(nestedContent) else {
                throw Error.badReplyContent
            }
            return ContentJson(type: ContentTypeReply, content: Reply(
                    reference: reply["reference"] as? String ?? "",
                    content: nested.content,
                    contentType: nested.type
            ))
        } else if let attachment = obj["attachment"] as? [String: Any] {
            guard let data = Data(base64Encoded: (attachment["data"] as? String) ?? "") else {
                throw Error.badAttachmentData
            }
            return ContentJson(type: ContentTypeAttachment, content: Attachment(
                    filename: attachment["filename"] as? String ?? "",
                    mimeType: attachment["mimeType"] as? String ?? "",
                    data: data
            ))
        } else if let remoteAttachment = obj["remoteAttachment"] as? [String: Any] {
            guard let metadata = try? EncryptedAttachmentMetadata.fromJsonObj(remoteAttachment) else {
                throw Error.badRemoteAttachmentMetadata
            }
            guard var content = try? RemoteAttachment(
              url: remoteAttachment["url"] as? String ?? "",
              contentDigest: metadata.contentDigest,
              secret: metadata.secret,
              salt: metadata.salt,
              nonce: metadata.nonce,
              scheme: RemoteAttachment.Scheme.https
            ) else {
              throw Error.badRemoteAttachmentMetadata
            }
            content.filename = metadata.filename
            content.contentLength = metadata.contentLength
            return ContentJson(type: ContentTypeRemoteAttachment, content: content)
        } else {
            throw Error.unknownContentType
        }
    }

    static func fromJson(_ json: String) throws -> ContentJson {
        let data = json.data(using: .utf8)!
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return try fromJsonObj(obj)
    }

    func toJsonMap() -> [String: Any] {
        switch type.id {
        case ContentTypeText.id:
            return ["text": content]
        case ContentTypeReaction.id where content is XMTP.Reaction:
            let reaction = content as! XMTP.Reaction
            return ["reaction": [
                "reference": reaction.reference,
                "action": reaction.action.rawValue,
                "schema": reaction.schema.rawValue,
                "content": reaction.content
                ]]
        case ContentTypeReply.id where content is XMTP.Reply:
            let reply = content as! XMTP.Reply
            let nested = ContentJson(type: reply.contentType, content: reply.content)
            return ["reply": [
                "reference": reply.reference,
                "content": nested.toJsonMap()
            ] as [String : Any]]
        case ContentTypeAttachment.id where content is XMTP.Attachment:
            let attachment = content as! XMTP.Attachment
            return ["attachment": [
                "filename": attachment.filename,
                "mimeType": attachment.mimeType,
                "data": attachment.data.base64EncodedString()
            ]]
        case ContentTypeRemoteAttachment.id where content is XMTP.RemoteAttachment:
            let remoteAttachment = content as! XMTP.RemoteAttachment
            return ["remoteAttachment": [
                "filename": remoteAttachment.filename ?? "",
                "secret": remoteAttachment.secret.toHex,
                "salt": remoteAttachment.salt.toHex,
                "nonce": remoteAttachment.nonce.toHex,
                "contentDigest": remoteAttachment.contentDigest,
                "contentLength": String(remoteAttachment.contentLength ?? 0),
                "scheme": "https://",
                "url": remoteAttachment.url
            ]]
        default:
            return ["unknown": ["contentTypeId": type.id]]
        }
    }
}

struct EncryptedAttachmentMetadata {
    var filename: String
    var secret: Data
    var salt: Data
    var nonce: Data
    var contentDigest: String
    var contentLength: Int

    enum Error: Swift.Error {
        case badRemoteAttachmentMetadata
    }

    static func fromAttachment(attachment: XMTP.Attachment,
                     encrypted: XMTP.EncryptedEncodedContent) throws -> EncryptedAttachmentMetadata {
        return EncryptedAttachmentMetadata(
                filename: attachment.filename,
                secret: encrypted.secret,
                salt: encrypted.salt,
                nonce: encrypted.nonce,
                contentDigest: encrypted.digest,
                contentLength: attachment.data.count
        )
    }

    static func fromJsonObj(_ obj: [String: Any]) throws -> EncryptedAttachmentMetadata {
        guard let secret = (obj["secret"] as? String ?? "").web3.hexData else {
            throw Error.badRemoteAttachmentMetadata
        }
        guard let salt = (obj["salt"] as? String ?? "").web3.hexData else {
            throw Error.badRemoteAttachmentMetadata
        }
        guard let nonce = (obj["nonce"] as? String ?? "").web3.hexData else {
            throw Error.badRemoteAttachmentMetadata
        }
        return EncryptedAttachmentMetadata(
                filename: obj["filename"] as? String ?? "",
                secret: secret,
                salt: salt,
                nonce: nonce,
                contentDigest: obj["contentDigest"] as? String ?? "",
                contentLength: Int(obj["contentLength"] as? String ?? "") ?? 0
        )
    }

    func toJsonMap() -> [String: Any] {
        return [ // RemoteAttachmentMetadata
            "filename": filename,
            "secret": secret.toHex,
            "salt": salt.toHex,
            "nonce": nonce.toHex,
            "contentDigest": contentDigest,
            "contentLength": String(contentLength)
        ]
    }

}

struct EncryptedLocalAttachment {
    var encryptedLocalFileUri: String
    var metadata: EncryptedAttachmentMetadata

    static func from(attachment: XMTP.Attachment,
                     encrypted: XMTP.EncryptedEncodedContent,
                     encryptedFile: URL)
        throws -> EncryptedLocalAttachment {
        return EncryptedLocalAttachment(
                encryptedLocalFileUri: encryptedFile.absoluteString,
                metadata: try EncryptedAttachmentMetadata.fromAttachment(
                        attachment: attachment,
                        encrypted: encrypted
                ))
    }

    static func fromJson(_ json: String) throws -> EncryptedLocalAttachment {
        let data = json.data(using: .utf8)!
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return EncryptedLocalAttachment(
            encryptedLocalFileUri: obj["encryptedLocalFileUri"] as? String ?? "",
            metadata: try EncryptedAttachmentMetadata.fromJsonObj(obj["metadata"] as? [String: Any] ?? [:])
        )
    }

    func toJson() throws -> String {
        let obj: [String: Any] = [
            "encryptedLocalFileUri": encryptedLocalFileUri,
            "metadata": metadata.toJsonMap()
        ]
        return try obj.toJson()
    }
}

struct DecryptedLocalAttachment {
  var fileUri: String
  var mimeType: String

  static func fromJson(_ json: String) throws -> DecryptedLocalAttachment {
    let data = json.data(using: .utf8)!
    let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return DecryptedLocalAttachment(
      fileUri: obj["fileUri"] as? String ?? "",
      mimeType: obj["mimeType"] as? String ?? ""
    )
  }

  func toJson() throws -> String {
    let obj: [String: Any] = [
      "fileUri": fileUri,
      "mimeType": mimeType
    ]
    return try obj.toJson()
  }
}

extension [String: Any] {
    func toJson() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: self)
        guard let result = String(data: data, encoding: .utf8) else {
            throw WrapperError.encodeError("could not encode json")
        }
        return result
    }
}

extension Data {
    // Cribbed from xmtp-ios
    var toHex: String {
        return reduce("") { $0 + String(format: "%02x", $1) }
    }
}
