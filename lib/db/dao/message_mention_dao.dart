import 'package:drift/drift.dart';

import '../../utils/extension/extension.dart';
import '../../utils/reg_exp_utils.dart';
import '../mixin_database.dart';

part 'message_mention_dao.g.dart';

@DriftAccessor(tables: [MessageMentions])
class MessageMentionDao extends DatabaseAccessor<MixinDatabase>
    with _$MessageMentionDaoMixin {
  MessageMentionDao(MixinDatabase db) : super(db);

  Future<int> insert(MessageMention messageMention) =>
      into(db.messageMentions).insertOnConflictUpdate(messageMention);

  Future deleteMessageMention(MessageMention messageMention) =>
      delete(db.messageMentions).delete(messageMention);

  Future<int> deleteMessageMentionByMessageId(String messageId) =>
      (db.delete(db.messageMentions)
            ..where((tbl) => tbl.messageId.equals(messageId)))
          .go();

  Future<void> parseMentionData(
    String? content,
    String messageId,
    String conversationId,
    String senderId,
    QuoteMessageItem? quoteMessage,
    String currentUserId,
    String currentUserIdentityNumber,
  ) async {
    var mentionMe = false;
    if (content?.isNotEmpty == true) {
      final numbers =
          mentionNumberRegExp.allMatchesAndSort(content!).map((e) => e[1]!);
      mentionMe = senderId != currentUserId &&
          numbers.contains(currentUserIdentityNumber);
    }

    if (!mentionMe &&
        quoteMessage != null &&
        quoteMessage.userId == currentUserId &&
        senderId != currentUserId) {
      mentionMe = true;
    }

    if (!mentionMe) return;

    await insert(MessageMention(
      messageId: messageId,
      conversationId: conversationId,
      hasRead: false,
    ));
  }

  SimpleSelectStatement<MessageMentions, MessageMention>
      unreadMentionMessageByConversationId(String conversationId) =>
          (db.select(db.messageMentions)
            ..where((tbl) =>
                tbl.conversationId.equals(conversationId) &
                tbl.hasRead.equals(false)));

  Future<int> markMentionRead(String messageId) =>
      (db.update(db.messageMentions)
            ..where((tbl) => tbl.messageId.equals(messageId)))
          .write(const MessageMentionsCompanion(hasRead: Value(true)));
}
