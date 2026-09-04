#include "include/CLexbor.h"

#include <stdatomic.h>
#include <stdlib.h>

struct YLXDocument {
    lxb_html_document_t *html;
    bool style_initialized;
};

static _Atomic size_t ylx_live_document_count = 0;

const char *
ylx_lexbor_version(void)
{
    return LEXBOR_VERSION_STRING;
}

static size_t
ylx_count_elements(const lxb_dom_node_t *node)
{
    size_t count = 0;

    for (const lxb_dom_node_t *current = node; current != NULL;
         current = current->next)
    {
        if (current->type == LXB_DOM_NODE_TYPE_ELEMENT) {
            count += 1;
        }

        if (current->first_child != NULL) {
            count += ylx_count_elements(current->first_child);
        }
    }

    return count;
}

YLXDocument *
ylx_document_create(const uint8_t *bytes, size_t length, YLXStatus *status)
{
    YLXDocument *document = NULL;
    lxb_status_t parse_status;

    if (status != NULL) {
        *status = YLX_STATUS_INVALID_ARGUMENT;
    }
    if (bytes == NULL || length == 0) {
        return NULL;
    }

    document = calloc(1, sizeof(YLXDocument));
    if (document == NULL) {
        if (status != NULL) {
            *status = YLX_STATUS_OUT_OF_MEMORY;
        }
        return NULL;
    }

    document->html = lxb_html_document_create();
    if (document->html == NULL) {
        if (status != NULL) {
            *status = YLX_STATUS_OUT_OF_MEMORY;
        }
        free(document);
        return NULL;
    }

    parse_status = lxb_html_document_parse(document->html,
                                           (const lxb_char_t *) bytes,
                                           length);
    if (parse_status != LXB_STATUS_OK) {
        if (status != NULL) {
            *status = parse_status == LXB_STATUS_ERROR_MEMORY_ALLOCATION
                ? YLX_STATUS_OUT_OF_MEMORY
                : YLX_STATUS_PARSE_ERROR;
        }
        document->html = lxb_html_document_destroy(document->html);
        free(document);
        return NULL;
    }

    atomic_fetch_add_explicit(&ylx_live_document_count, 1,
                              memory_order_relaxed);
    if (status != NULL) {
        *status = YLX_STATUS_OK;
    }
    return document;
}

void
ylx_document_destroy(YLXDocument *document)
{
    if (document == NULL) {
        return;
    }

    if (document->style_initialized) {
        lxb_style_destroy(document->html);
        document->style_initialized = false;
    }
    if (document->html != NULL) {
        document->html = lxb_html_document_destroy(document->html);
    }

    atomic_fetch_sub_explicit(&ylx_live_document_count, 1,
                              memory_order_relaxed);
    free(document);
}

size_t
ylx_document_element_count(const YLXDocument *document)
{
    if (document == NULL || document->html == NULL) {
        return 0;
    }

    return ylx_count_elements(lxb_dom_interface_node(document->html));
}

size_t
ylx_debug_live_document_count(void)
{
    return atomic_load_explicit(&ylx_live_document_count,
                                memory_order_relaxed);
}
