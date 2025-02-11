import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mixin_bot_sdk_dart/mixin_bot_sdk_dart.dart';
import 'package:stream_transform/stream_transform.dart';

import '../blaze/vo/pin_message_minimal.dart';
import '../db/extension/conversation.dart';
import '../enum/message_category.dart';
import '../generated/l10n.dart';
import '../ui/home/bloc/conversation_cubit.dart';
import '../ui/home/bloc/slide_category_cubit.dart';
import '../utils/app_lifecycle.dart';
import '../utils/extension/extension.dart';
import '../utils/load_balancer_utils.dart';
import '../utils/local_notification_center.dart';
import '../utils/message_optimize.dart';
import '../utils/reg_exp_utils.dart';
import '../widgets/message/item/pin_message.dart';
import '../widgets/message/item/system_message.dart';
import '../widgets/message/item/text/mention_builder.dart';

class NotificationService {
  NotificationService({
    required BuildContext context,
  }) {
    streamSubscriptions
      ..add(context.database.messageDao.notificationMessageStream
          .where((event) => event.type == MessageCategory.messageRecall)
          .asyncMap((event) => dismissByMessageId(event.messageId))
          .listen((event) {}))
      ..add(context.database.messageDao.notificationMessageStream
          .where((event) {
            if (isAppActive) {
              final conversationState = context.read<ConversationCubit>().state;
              return event.conversationId !=
                  (conversationState?.conversationId ??
                      conversationState?.conversation?.conversationId);
            }
            return true;
          })
          .where((event) => event.senderId != context.accountServer.userId)
          .where((event) => event.type != MessageCategory.messageRecall)
          .asyncWhere((event) async {
            final muteUntil = event.category == ConversationCategory.group
                ? event.muteUntil
                : event.ownerMuteUntil;
            if (muteUntil?.isAfter(DateTime.now()) != true) return true;

            if (!event.type.isText) return false;

            final account = context.multiAuthState.currentUser!;

            // mention current user
            if (mentionNumberRegExp
                .allMatchesAndSort(event.content ?? '')
                .any((element) => element[1] == account.identityNumber)) {
              return true;
            }

            // quote current user
            if (event.quoteContent?.isNotEmpty ?? false) {
              // ignore: avoid_dynamic_calls
              if ((await jsonDecodeWithIsolate(event.quoteContent ?? '') ??
                      {})['user_id'] ==
                  account.userId) return true;
            }

            return false;
          })
          .where((event) => event.createdAt
              .isAfter(DateTime.now().subtract(const Duration(minutes: 2))))
          .asyncMap((event) async {
            final name = conversationValidName(
              event.groupName,
              event.ownerFullName,
            );

            String? body;
            if (context.multiAuthState.currentMessagePreview) {
              if (event.type == MessageCategory.systemConversation) {
                body = generateSystemText(
                  actionName: event.actionName,
                  participantUserId: event.participantUserId,
                  senderId: event.senderId,
                  currentUserId: context.accountServer.userId,
                  participantFullName: event.participantFullName,
                  senderFullName: event.senderFullName,
                  groupName: event.groupName,
                );
              } else if (event.type.isPin) {
                final pinMessageMinimal =
                    PinMessageMinimal.fromJsonString(event.content ?? '');

                if (pinMessageMinimal == null) {
                  body = Localization.current.pinned(event.senderFullName ?? '',
                      Localization.current.aMessage);
                } else {
                  final preview = await generatePinPreviewText(
                    pinMessageMinimal: pinMessageMinimal,
                    mentionCache: context.read<MentionCache>(),
                  );

                  body = Localization.current
                      .pinned(event.senderFullName ?? '', preview);
                }
              } else {
                final isGroup = event.category == ConversationCategory.group ||
                    event.senderId != event.ownerUserId;

                if (event.type.isText) {
                  final mentionCache = context.read<MentionCache>();
                  body = mentionCache.replaceMention(
                    event.content,
                    await mentionCache.checkMentionCache({event.content!}),
                  );
                }
                body = messagePreviewOptimize(
                  event.status,
                  event.type,
                  body,
                  false,
                  isGroup,
                  event.senderFullName,
                );
              }
              body ??= Localization.current.chatNotSupport;
            } else {
              body = Localization.current.sentYouAMessage;
            }

            await showNotification(
              title: name,
              body: body,
              uri: Uri(
                scheme: enumConvertToString(NotificationScheme.conversation),
                host: event.conversationId,
                path: event.messageId,
              ),
              messageId: event.messageId,
              conversationId: event.conversationId,
            );
          })
          .listen((_) {}))
      ..add(
        notificationSelectEvent(NotificationScheme.conversation).listen(
          (event) {
            final slideCategoryCubit = context.read<SlideCategoryCubit>();
            if (slideCategoryCubit.state.type == SlideCategoryType.setting) {
              slideCategoryCubit.select(SlideCategoryType.chats);
            }
            ConversationCubit.selectConversation(
              context,
              event.host,
              initIndexMessageId: event.path,
            );
          },
        ),
      );
  }

  List<StreamSubscription> streamSubscriptions = [];

  Future<void> close() async {
    await Future.wait(streamSubscriptions.map((e) => e.cancel()));
  }
}
