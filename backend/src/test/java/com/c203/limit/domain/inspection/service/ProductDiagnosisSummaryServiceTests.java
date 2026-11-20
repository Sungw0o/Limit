package com.c203.limit.domain.inspection.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.c203.limit.domain.inspection.dto.response.DiagnosisSummaryItem;
import com.c203.limit.domain.inspection.dto.response.ProductDiagnosisSummaryResponse;
import com.c203.limit.domain.inspection.entity.ListingChecklistItem;
import com.c203.limit.domain.inspection.enums.DiagnosisFieldName;
import com.c203.limit.domain.inspection.enums.DiagnosisSourceType;
import com.c203.limit.domain.inspection.enums.DiagnosisSummaryStatus;
import com.c203.limit.domain.inspection.repository.ListingChecklistItemRepository;
import com.c203.limit.domain.inspection.repository.ListingOwnerReader;
import com.c203.limit.global.exception.BusinessException;
import com.c203.limit.global.exception.ErrorCode;
import java.util.EnumMap;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class ProductDiagnosisSummaryServiceTests {

    private static final Long PRODUCT_ID = 1L;
    private static final Long SELLER_ID = 100L;
    private static final Long ITEM_ID = 2L;
    private static final DiagnosisAggregationService.DiagnosisFieldValue EMPTY =
            new DiagnosisAggregationService.DiagnosisFieldValue(null, null, null, null);

    @Mock ListingOwnerReader listingOwnerReader;
    @Mock ListingChecklistItemRepository listingChecklistItemRepository;
    @Mock DiagnosisAggregationService diagnosisAggregationService;

    ProductDiagnosisSummaryService service;

    @BeforeEach
    void setUp() {
        service =
                new ProductDiagnosisSummaryService(
                        listingOwnerReader, listingChecklistItemRepository, diagnosisAggregationService);
    }

    private void stubProductExists() {
        when(listingOwnerReader.findById(PRODUCT_ID))
                .thenReturn(Optional.of(new ListingOwnerReader.ListingOwnerInfo(PRODUCT_ID, SELLER_ID)));
    }

    private DiagnosisSummaryItem fieldNamed(ProductDiagnosisSummaryResponse response, String fieldName) {
        return response.items().stream()
                .filter(item -> item.fieldName().equals(fieldName))
                .findFirst()
                .orElseThrow(() -> new AssertionError("field not found: " + fieldName));
    }

    /** 항목 하나에 대해 전체 필드를 EMPTY로 채운 기본 맵(배치 응답 스텁용). */
    private Map<DiagnosisFieldName, DiagnosisAggregationService.DiagnosisFieldValue> allFieldsEmpty() {
        Map<DiagnosisFieldName, DiagnosisAggregationService.DiagnosisFieldValue> map =
                new EnumMap<>(DiagnosisFieldName.class);
        for (DiagnosisFieldName fieldName : DiagnosisFieldName.values()) {
            map.put(fieldName, EMPTY);
        }
        return map;
    }

    @Test
    void mixesAvailableAndExtractionFailedFields() {
        stubProductExists();
        ListingChecklistItem item = mock(ListingChecklistItem.class);
        when(item.getId()).thenReturn(ITEM_ID);
        List<ListingChecklistItem> items = List.of(item);
        when(listingChecklistItemRepository.findAllByListingIdOrderByDisplayOrderAsc(PRODUCT_ID))
                .thenReturn(items);

        Map<DiagnosisFieldName, DiagnosisAggregationService.DiagnosisFieldValue> itemFields = allFieldsEmpty();
        itemFields.put(
                DiagnosisFieldName.CPU,
                new DiagnosisAggregationService.DiagnosisFieldValue(
                        "ocr cpu", "file cpu", 5L, DiagnosisSourceType.DXDIAG));

        Map<Long, Map<DiagnosisFieldName, DiagnosisAggregationService.DiagnosisFieldValue>> fieldValuesByItemId =
                new HashMap<>();
        fieldValuesByItemId.put(ITEM_ID, itemFields);
        Map<Long, String> cdnUrlByEvidenceId = Map.of(5L, "https://cdn.example.com/evidence/5.txt");

        when(diagnosisAggregationService.getFieldValuesForListing(PRODUCT_ID, items))
                .thenReturn(
                        new DiagnosisAggregationService.ListingDiagnosisBatch(fieldValuesByItemId, cdnUrlByEvidenceId));

        ProductDiagnosisSummaryResponse response = service.getSummary(PRODUCT_ID);

        assertThat(response.productId()).isEqualTo(PRODUCT_ID);
        assertThat(response.disclaimer())
                .isEqualTo("자동 추출값은 참고 정보이며 상품의 정상 여부를 보증하지 않습니다.");
        assertThat(response.items()).hasSize(DiagnosisFieldName.values().length);

        DiagnosisSummaryItem cpu = fieldNamed(response, "CPU");
        assertThat(cpu.value()).isEqualTo("file cpu");
        assertThat(cpu.status()).isEqualTo(DiagnosisSummaryStatus.AVAILABLE);
        assertThat(cpu.originalFileUrl()).isEqualTo("https://cdn.example.com/evidence/5.txt");

        DiagnosisSummaryItem gpu = fieldNamed(response, "GPU");
        assertThat(gpu.value()).isNull();
        assertThat(gpu.originalFileUrl()).isNull();
        assertThat(gpu.status()).isEqualTo(DiagnosisSummaryStatus.EXTRACTION_FAILED);
    }

    @Test
    void dedupesSameFieldAcrossMultipleChecklistItemsPreferringAvailable() {
        stubProductExists();
        Long ocrItemId = 3L;
        Long dxdiagItemId = 4L;
        ListingChecklistItem ocrItem = mock(ListingChecklistItem.class);
        when(ocrItem.getId()).thenReturn(ocrItemId);
        ListingChecklistItem dxdiagItem = mock(ListingChecklistItem.class);
        when(dxdiagItem.getId()).thenReturn(dxdiagItemId);
        List<ListingChecklistItem> items = List.of(ocrItem, dxdiagItem);
        when(listingChecklistItemRepository.findAllByListingIdOrderByDisplayOrderAsc(PRODUCT_ID))
                .thenReturn(items);

        // OCR 항목은 CPU 인식에 실패했고, DXDIAG 항목이 대신 CPU 값을 갖고 있는 상황.
        Map<DiagnosisFieldName, DiagnosisAggregationService.DiagnosisFieldValue> ocrItemFields = allFieldsEmpty();
        Map<DiagnosisFieldName, DiagnosisAggregationService.DiagnosisFieldValue> dxdiagItemFields = allFieldsEmpty();
        dxdiagItemFields.put(
                DiagnosisFieldName.CPU,
                new DiagnosisAggregationService.DiagnosisFieldValue(
                        null, "dxdiag cpu", 7L, DiagnosisSourceType.DXDIAG));

        Map<Long, Map<DiagnosisFieldName, DiagnosisAggregationService.DiagnosisFieldValue>> fieldValuesByItemId =
                new HashMap<>();
        fieldValuesByItemId.put(ocrItemId, ocrItemFields);
        fieldValuesByItemId.put(dxdiagItemId, dxdiagItemFields);
        Map<Long, String> cdnUrlByEvidenceId = Map.of(7L, "https://cdn.example.com/evidence/7.txt");

        when(diagnosisAggregationService.getFieldValuesForListing(PRODUCT_ID, items))
                .thenReturn(
                        new DiagnosisAggregationService.ListingDiagnosisBatch(fieldValuesByItemId, cdnUrlByEvidenceId));

        ProductDiagnosisSummaryResponse response = service.getSummary(PRODUCT_ID);

        assertThat(response.items()).hasSize(DiagnosisFieldName.values().length);
        DiagnosisSummaryItem cpu = fieldNamed(response, "CPU");
        assertThat(cpu.status()).isEqualTo(DiagnosisSummaryStatus.AVAILABLE);
        assertThat(cpu.value()).isEqualTo("dxdiag cpu");
        assertThat(cpu.originalFileUrl()).isEqualTo("https://cdn.example.com/evidence/7.txt");
    }

    @Test
    void throwsProductNotFoundWhenListingDoesNotExist() {
        when(listingOwnerReader.findById(PRODUCT_ID)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.getSummary(PRODUCT_ID))
                .isInstanceOfSatisfying(
                        BusinessException.class,
                        exception -> assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.PRODUCT_NOT_FOUND));
    }
}
