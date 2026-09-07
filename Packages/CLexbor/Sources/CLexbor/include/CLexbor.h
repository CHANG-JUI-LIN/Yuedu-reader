#ifndef YUEDU_CLEXBOR_H
#define YUEDU_CLEXBOR_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct YLXDocument YLXDocument;

typedef enum {
    YLX_STATUS_OK = 0,
    YLX_STATUS_INVALID_ARGUMENT = 1,
    YLX_STATUS_PARSE_ERROR = 2,
    YLX_STATUS_OUT_OF_MEMORY = 3
} YLXStatus;

typedef struct {
    const uint8_t *bytes;
    size_t length;
} YLXBytes;

typedef struct {
    uint64_t node_id;
    uint64_t parent_node_id;
    uint32_t sibling_ordinal;
    YLXBytes namespace_name;
    YLXBytes tag_name;
} YLXElementSnapshot;

typedef struct {
    YLXBytes property;
    YLXBytes value;
    YLXBytes selector;
    uint32_t specificity;
    uint32_t source_order;
    uint8_t origin;
    uint8_t important;
} YLXWinningDeclaration;

typedef int (*YLXElementCallback)(const YLXElementSnapshot *, void *);
typedef int (*YLXAttributeCallback)(uint64_t, YLXBytes, YLXBytes, void *);
typedef int (*YLXTextCallback)(uint64_t, YLXBytes, void *);
typedef int (*YLXDeclarationCallback)(uint64_t, const YLXWinningDeclaration *, void *);

const char *ylx_lexbor_version(void);
YLXDocument *ylx_document_create(const uint8_t *bytes, size_t length,
                                 YLXStatus *status);
void ylx_document_destroy(YLXDocument *document);
size_t ylx_document_element_count(const YLXDocument *document);
size_t ylx_debug_live_document_count(void);

YLXStatus ylx_document_attach_stylesheet(YLXDocument *, const uint8_t *, size_t,
                                         uint32_t source_order);
YLXStatus ylx_document_walk(const YLXDocument *, YLXElementCallback,
                            YLXAttributeCallback, YLXTextCallback, void *);
YLXStatus ylx_document_walk_winning_declarations(const YLXDocument *,
                                                  YLXDeclarationCallback, void *);

#endif /* YUEDU_CLEXBOR_H */
