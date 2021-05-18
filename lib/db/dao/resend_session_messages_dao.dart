import 'package:moor/moor.dart';

import '../mixin_database.dart';

part 'resend_session_messages_dao.g.dart';

@UseDao(tables: [ResendSessionMessages])
class ResendSessionMessagesDao extends DatabaseAccessor<MixinDatabase>
    with _$ResendSessionMessagesDaoMixin {
  ResendSessionMessagesDao(MixinDatabase db) : super(db);

  Future<int> insert(ResendSessionMessage resendSessionMessage) =>
      into(db.resendSessionMessages)
          .insertOnConflictUpdate(resendSessionMessage);

  Future<int> deleteResendSessionMessageById(String messageId) =>
      (delete(db.resendSessionMessages)
            ..where((tbl) => tbl.messageId.equals(messageId)))
          .go();

  Future<ResendSessionMessage?> findResendMessage(
          String userId, String sessionId, String messageId) async =>
      (select(db.resendSessionMessages)
            ..where((tbl) =>
                tbl.userId.equals(userId) &
                tbl.sessionId.equals(sessionId) &
                tbl.messageId.equals(messageId)))
          .getSingleOrNull();
}
