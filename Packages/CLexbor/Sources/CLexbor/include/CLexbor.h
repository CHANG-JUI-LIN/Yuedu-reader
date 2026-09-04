#ifndef YUEDU_CLEXBOR_H
#define YUEDU_CLEXBOR_H

#include <stddef.h>
#include <stdint.h>

typedef struct YLXDocument YLXDocument;

typedef enum {
    YLX_STATUS_OK = 0,
    YLX_STATUS_INVALID_ARGUMENT = 1,
    YLX_STATUS_PARSE_ERROR = 2,
    YLX_STATUS_OUT_OF_MEMORY = 3
} YLXStatus;

const char *ylx_lexbor_version(void);
YLXDocument *ylx_document_create(const uint8_t *bytes, size_t length,
                                 YLXStatus *status);
void ylx_document_destroy(YLXDocument *document);
size_t ylx_document_element_count(const YLXDocument *document);
size_t ylx_debug_live_document_count(void);

#endif /* YUEDU_CLEXBOR_H */
