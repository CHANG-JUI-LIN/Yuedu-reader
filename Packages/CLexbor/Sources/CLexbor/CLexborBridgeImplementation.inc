#include "include/CLexbor.h"

#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <strings.h>

typedef struct {
    const lxb_css_rule_declaration_t *declaration;
    uint32_t source_order;
} YLXDeclarationMetadata;

struct YLXDocument {
    lxb_html_document_t *html;
    bool style_initialized;
    YLXDeclarationMetadata *declarations;
    size_t declaration_count;
    size_t declaration_capacity;
};

typedef struct {
    const YLXDocument *document;
    YLXElementCallback element;
    YLXAttributeCallback attribute;
    YLXTextCallback text;
    YLXDeclarationCallback declaration;
    void *context;
    uint64_t next_id;
} YLXWalkContext;

typedef struct {
    uint8_t *data;
    size_t length;
    size_t capacity;
} YLXBuffer;

static lxb_status_t ylx_buffer_append(const lxb_char_t *data, size_t length, void *ctx)
{
    YLXBuffer *buffer = ctx;
    if (length == 0) return LXB_STATUS_OK;
    if (buffer->length > SIZE_MAX - length) return LXB_STATUS_ERROR_MEMORY_ALLOCATION;
    size_t required = buffer->length + length;
    if (required > buffer->capacity) {
        size_t capacity = buffer->capacity == 0 ? 64 : buffer->capacity;
        while (capacity < required) {
            if (capacity > SIZE_MAX / 2) return LXB_STATUS_ERROR_MEMORY_ALLOCATION;
            capacity *= 2;
        }
        uint8_t *data = realloc(buffer->data, capacity);
        if (data == NULL) return LXB_STATUS_ERROR_MEMORY_ALLOCATION;
        buffer->data = data;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    return LXB_STATUS_OK;
}

static YLXBytes ylx_bytes(const lxb_char_t *data, size_t length)
{
    YLXBytes result = { (const uint8_t *) data, length };
    return result;
}

static void ylx_record_rule_list(YLXDocument *document, lxb_css_rule_list_t *list,
                                 uint32_t source_order)
{
    if (list == NULL) return;
    for (lxb_css_rule_t *rule = list->first; rule != NULL; rule = rule->next) {
        if (rule->type != LXB_CSS_RULE_STYLE) continue;
        lxb_css_rule_style_t *style = lxb_css_rule_style(rule);
        if (style->declarations != NULL) {
            for (lxb_css_rule_t *decl_rule = style->declarations->first;
                 decl_rule != NULL; decl_rule = decl_rule->next) {
                if (decl_rule->type != LXB_CSS_RULE_DECLARATION) continue;
                if (document->declaration_count == document->declaration_capacity) {
                    size_t capacity = document->declaration_capacity == 0 ? 32 : document->declaration_capacity * 2;
                    YLXDeclarationMetadata *metadata = realloc(document->declarations,
                        capacity * sizeof(YLXDeclarationMetadata));
                    if (metadata == NULL) return;
                    document->declarations = metadata;
                    document->declaration_capacity = capacity;
                }
                document->declarations[document->declaration_count++] = (YLXDeclarationMetadata){
                    lxb_css_rule_declaration(decl_rule), source_order
                };
            }
        }
        ylx_record_rule_list(document, style->child, source_order);
    }
}

static uint32_t ylx_source_order(const YLXDocument *document,
                                 const lxb_css_rule_declaration_t *declaration)
{
    for (size_t index = 0; index < document->declaration_count; index++) {
        if (document->declarations[index].declaration == declaration) {
            return document->declarations[index].source_order;
        }
    }
    return 0;
}

static int ylx_walk_node(lxb_dom_node_t *node, uint64_t parent_id,
                         YLXWalkContext *context)
{
    for (lxb_dom_node_t *current = node; current != NULL; current = current->next) {
        uint64_t node_id = ++context->next_id;
        if (current->type == LXB_DOM_NODE_TYPE_ELEMENT) {
            size_t tag_length = 0;
            size_t namespace_length = 0;
            const lxb_char_t *tag = lxb_dom_node_name(current, &tag_length);
            const lxb_char_t *ns = lxb_ns_by_id(
                lxb_dom_interface_document(current->owner_document)->ns,
                (lxb_ns_id_t) current->ns, &namespace_length);
            uint32_t sibling = 0;
            for (lxb_dom_node_t *prior = current->parent ? current->parent->first_child : NULL;
                 prior != current; prior = prior->next) {
                if (prior->type == LXB_DOM_NODE_TYPE_ELEMENT) sibling++;
            }
            YLXElementSnapshot snapshot = {
                node_id, parent_id, sibling,
                ylx_bytes(ns, namespace_length), ylx_bytes(tag, tag_length)
            };
            if (context->element != NULL && !context->element(&snapshot, context->context)) return 0;
            lxb_dom_element_t *element = lxb_dom_interface_element(current);
            for (lxb_dom_attr_t *attr = element->first_attr; attr != NULL; attr = attr->next) {
                size_t name_length = 0;
                const lxb_char_t *name = lxb_dom_node_name(lxb_dom_interface_node(attr), &name_length);
                const lxb_char_t *value = attr->value == NULL ? NULL : attr->value->data;
                size_t value_length = attr->value == NULL ? 0 : attr->value->length;
                if (context->attribute != NULL
                    && !context->attribute(node_id, ylx_bytes(name, name_length),
                                           ylx_bytes(value, value_length), context->context)) return 0;
            }
        }
        else if (current->type == LXB_DOM_NODE_TYPE_TEXT && context->text != NULL) {
            lxb_dom_character_data_t *text = lxb_dom_interface_character_data(current);
            if (!context->text(node_id, ylx_bytes(text->data.data, text->data.length), context->context)) return 0;
        }
        if (current->first_child != NULL && !ylx_walk_node(current->first_child, node_id, context)) return 0;
    }
    return 1;
}

static lxb_status_t ylx_walk_declaration(lxb_dom_element_t *element,
                                          const lxb_css_rule_declaration_t *declaration,
                                          void *ctx, lxb_css_selector_specificity_t specificity,
                                          bool is_weak)
{
    (void) is_weak;
    YLXWalkContext *context = ctx;
    YLXBuffer name = {0};
    YLXBuffer value = {0};
    const lxb_css_entry_data_t *property = lxb_css_property_by_id(declaration->type);
    if (property == NULL || ylx_buffer_append(property->name, property->length, &name) != LXB_STATUS_OK
        || lxb_css_property_serialize(declaration->u.user, declaration->type,
                                      ylx_buffer_append, &value) != LXB_STATUS_OK) {
        free(name.data); free(value.data); return LXB_STATUS_ERROR_MEMORY_ALLOCATION;
    }
    uint64_t node_id = context->next_id;
    YLXWinningDeclaration snapshot = {
        ylx_bytes(name.data, name.length), ylx_bytes(value.data, value.length),
        { NULL, 0 }, specificity, ylx_source_order(context->document, declaration),
        (uint8_t) (lxb_css_selector_sp_s(specificity) ? 1 : 0),
        declaration->important ? 1 : 0
    };
    int accepted = context->declaration == NULL || context->declaration(node_id, &snapshot, context->context);
    free(name.data); free(value.data);
    return accepted ? LXB_STATUS_OK : LXB_STATUS_STOP;
}

static int ylx_walk_declarations(lxb_dom_node_t *node, YLXWalkContext *context)
{
    for (lxb_dom_node_t *current = node; current != NULL; current = current->next) {
        context->next_id += 1;
        if (current->type == LXB_DOM_NODE_TYPE_ELEMENT) {
            lxb_dom_element_t *element = lxb_dom_interface_element(current);
            (void) lxb_dom_element_style_attach_exists(element);
            for (lxb_dom_attr_t *attr = element->first_attr; attr != NULL; attr = attr->next) {
                size_t name_length = 0;
                const lxb_char_t *name = lxb_dom_node_name(lxb_dom_interface_node(attr), &name_length);
                if (name != NULL && name_length == 5 && strncasecmp((const char *) name, "style", 5) == 0
                    && attr->value != NULL) {
                    (void) lxb_dom_element_style_parse(element, attr->value->data, attr->value->length);
                    break;
                }
            }
            if (element->style != NULL
                && lxb_dom_element_style_walk(element, ylx_walk_declaration,
                                               context, false) != LXB_STATUS_OK) return 0;
        }
        if (current->first_child != NULL && !ylx_walk_declarations(current->first_child, context)) return 0;
    }
    return 1;
}

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

    /* Initialize CSS before parsing so HTML style attributes/elements use the
       same Lexbor mutation hooks as authored stylesheets. */
    if (lxb_style_init(document->html) != LXB_STATUS_OK) {
        document->html = lxb_html_document_destroy(document->html);
        free(document);
        if (status != NULL) *status = YLX_STATUS_OUT_OF_MEMORY;
        return NULL;
    }
    document->style_initialized = true;

    parse_status = lxb_html_document_parse(document->html,
                                           (const lxb_char_t *) bytes,
                                           length);
    if (parse_status != LXB_STATUS_OK) {
        if (status != NULL) {
            *status = parse_status == LXB_STATUS_ERROR_MEMORY_ALLOCATION
                ? YLX_STATUS_OUT_OF_MEMORY
                : YLX_STATUS_PARSE_ERROR;
        }
        if (document->style_initialized) lxb_style_destroy(document->html);
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

YLXStatus
ylx_document_attach_stylesheet(YLXDocument *document, const uint8_t *bytes,
                               size_t length, uint32_t source_order)
{
    (void) source_order;
    if (document == NULL || bytes == NULL || length == 0) return YLX_STATUS_INVALID_ARGUMENT;
    if (!document->style_initialized) {
        if (lxb_style_init(document->html) != LXB_STATUS_OK) return YLX_STATUS_PARSE_ERROR;
        document->style_initialized = true;
    }
    lxb_dom_document_t *dom = lxb_dom_interface_document(document->html);
    lxb_css_parser_t *parser = lxb_css_parser_create();
    if (parser == NULL || lxb_css_parser_init(parser, NULL) != LXB_STATUS_OK
        || lxb_css_parser_selectors_init(parser) != LXB_STATUS_OK) {
        if (parser != NULL) lxb_css_parser_destroy(parser, true);
        return YLX_STATUS_OUT_OF_MEMORY;
    }
    lxb_css_stylesheet_t *sheet = lxb_css_stylesheet_create(dom->css->memory);
    lxb_status_t status = sheet == NULL ? LXB_STATUS_ERROR_MEMORY_ALLOCATION
        : lxb_css_stylesheet_parse(sheet, parser, (const lxb_char_t *) bytes, length);
    if (status == LXB_STATUS_OK) {
        ylx_record_rule_list(document, lxb_css_rule_list(sheet->root), source_order);
        status = lxb_dom_document_stylesheet_attach(dom, sheet);
    }
    if (status != LXB_STATUS_OK && sheet != NULL) lxb_css_stylesheet_destroy(sheet, false);
    lxb_css_parser_destroy(parser, true);
    return status == LXB_STATUS_OK ? YLX_STATUS_OK : YLX_STATUS_PARSE_ERROR;
}

YLXStatus
ylx_document_walk(const YLXDocument *document, YLXElementCallback element,
                  YLXAttributeCallback attribute, YLXTextCallback text, void *context)
{
    if (document == NULL || document->html == NULL) return YLX_STATUS_INVALID_ARGUMENT;
    YLXWalkContext walk = { document, element, attribute, text, NULL, context, 0 };
    return ylx_walk_node(lxb_dom_interface_node(document->html), 0, &walk)
        ? YLX_STATUS_OK : YLX_STATUS_PARSE_ERROR;
}

YLXStatus
ylx_document_walk_winning_declarations(const YLXDocument *document,
                                       YLXDeclarationCallback declaration, void *context)
{
    if (document == NULL || document->html == NULL || declaration == NULL) return YLX_STATUS_INVALID_ARGUMENT;
    if (!document->style_initialized) return YLX_STATUS_OK;
    YLXWalkContext walk = { document, NULL, NULL, NULL, declaration, context, 0 };
    return ylx_walk_declarations(lxb_dom_interface_node(document->html), &walk)
        ? YLX_STATUS_OK : YLX_STATUS_PARSE_ERROR;
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
    free(document->declarations);

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
