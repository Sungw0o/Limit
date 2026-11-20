package com.c203.limit.domain.chat.repository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import com.c203.limit.domain.chat.entity.ChatMessage;

public interface ChatMessageRepository extends JpaRepository<ChatMessage, Long> {
    Optional<ChatMessage> findByChatRoomIdAndClientMessageId(Long chatRoomId, UUID clientMessageId);

    @Query("""
            SELECT COUNT(message)
              FROM ChatMessage message
             WHERE message.chatRoomId = :roomId
               AND message.senderId <> :memberId
               AND message.roomSequence > :lastReadSeq
               AND message.deletedAt IS NULL
            """)
    long countUnreadFromCounterpart(
            @Param("roomId") Long roomId,
            @Param("memberId") Long memberId,
            @Param("lastReadSeq") long lastReadSeq);

    /**
     * {@link #countUnreadFromCounterpart}를 방마다 반복 호출하는 대신, 채팅방 목록 페이지 전체(N개 방)의
     * 미확인 개수를 한 번에 계산하기 위한 배치 조회. 방마다 lastReadSeq 기준점이 달라 SQL의 GROUP BY만으로는
     * 방별 개수를 낼 수 없으므로, "이 페이지에서 가장 오래된 기준점(minLastReadSeq)보다 뒤에 온 상대방 메시지"만
     * 결과로 가져오고, 방별 정확한 개수는 호출부에서 각 방의 실제 lastReadSeq로 다시 필터링한다.
     */
    @Query("""
            SELECT message.chatRoomId AS roomId, message.roomSequence AS roomSequence
              FROM ChatMessage message
             WHERE message.chatRoomId IN :roomIds
               AND message.senderId <> :memberId
               AND message.roomSequence > :minLastReadSeq
               AND message.deletedAt IS NULL
            """)
    List<UnreadMessageProjection> findCounterpartMessagesSince(
            @Param("roomIds") List<Long> roomIds,
            @Param("memberId") Long memberId,
            @Param("minLastReadSeq") long minLastReadSeq);

    @Query("""
            SELECT message.id AS messageId, message.roomSequence AS roomSequence,
                   message.senderId AS senderId, message.clientMessageId AS clientMessageId,
                   message.type AS type, message.content AS content,
                   message.status AS status, message.sentAt AS sentAt
              FROM ChatMessage message
             WHERE message.chatRoomId = :roomId
               AND message.deletedAt IS NULL
               AND (:beforeSeq IS NULL OR message.roomSequence < :beforeSeq)
             ORDER BY message.roomSequence DESC
            """)
    List<ChatMessageProjection> findBeforeSequence(@Param("roomId") Long roomId,
            @Param("beforeSeq") Long beforeSeq, Pageable pageable);

    @Query("""
            SELECT message.id AS messageId, message.roomSequence AS roomSequence,
                   message.senderId AS senderId, message.clientMessageId AS clientMessageId,
                   message.type AS type, message.content AS content,
                   message.status AS status, message.sentAt AS sentAt
              FROM ChatMessage message
             WHERE message.chatRoomId = :roomId
               AND message.deletedAt IS NULL
               AND message.roomSequence > :afterSeq
             ORDER BY message.roomSequence ASC
            """)
    List<ChatMessageProjection> findAfterSequence(@Param("roomId") Long roomId,
            @Param("afterSeq") Long afterSeq, Pageable pageable);
}
