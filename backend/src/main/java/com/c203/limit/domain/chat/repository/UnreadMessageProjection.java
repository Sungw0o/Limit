package com.c203.limit.domain.chat.repository;

/** 채팅방 목록의 미확인 개수를 방 단위로 배치 계산하기 위한 최소 투영(방 id, 상대방이 보낸 메시지의 방 내 순번). */
public interface UnreadMessageProjection {
    Long getRoomId();

    Long getRoomSequence();
}
