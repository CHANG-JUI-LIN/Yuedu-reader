#include "include/CLexbor.h"

#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <strings.h>

typedef struct {
    const lxb_css_rule_declaration_t *declaration;
    uint32_t source_order;
    lxb_css_selector_list_t *selector;
} YLXDeclarationMetadata;

struct YLXDocument {
    lxb_html_document_t *html;
    bool style_initialized;
    YLXStatus failure;
    YLXDeclarationMetadata *declarations;
    size_t declaration_count;
    size_t unparsed_declaration_count;
    size_t unsupported_rule_count;
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

static YLXStatus ylx_status(lxb_status_t status)
{
    if (status == LXB_STATUS_OK) return YLX_STATUS_OK;
    return status == LXB_STATUS_ERROR_MEMORY_ALLOCATION
        ? YLX_STATUS_OUT_OF_MEMORY : YLX_STATUS_PARSE_ERROR;
}

static lxb_status_t ylx_record_rule_list(YLXDocument *document, lxb_css_rule_list_t *list,
                                         uint32_t source_order)
{
    if (list == NULL) return LXB_STATUS_ERROR_WRONG_ARGS;
    for (lxb_css_rule_t *rule = list->first; rule != NULL; rule = rule->next) {
        if (rule->type != LXB_CSS_RULE_STYLE) {
            document->unsupported_rule_count += 1;
            continue;
        }
        lxb_css_rule_style_t *style = lxb_css_rule_style(rule);
        if (style->child != NULL) {
            for (lxb_css_rule_t *child = style->child->first; child != NULL; child = child->next) {
                document->unsupported_rule_count += 1;
            }
        }
        if (style->declarations == NULL) continue;
        for (lxb_css_rule_t *decl_rule = style->declarations->first;
             decl_rule != NULL; decl_rule = decl_rule->next) {
            if (decl_rule->type != LXB_CSS_RULE_DECLARATION) continue;
            if (lxb_css_rule_declaration(decl_rule)->type == LXB_CSS_PROPERTY__UNDEF) {
                document->unparsed_declaration_count += 1;
                continue;
            }
            if (document->declaration_count == document->declaration_capacity) {
                size_t old = document->declaration_capacity;
                if (old > SIZE_MAX / 2 / sizeof(YLXDeclarationMetadata)) {
                    return LXB_STATUS_ERROR_MEMORY_ALLOCATION;
                }
                size_t capacity = old == 0 ? 32 : old * 2;
                YLXDeclarationMetadata *metadata = realloc(document->declarations,
                    capacity * sizeof(YLXDeclarationMetadata));
                if (metadata == NULL) return LXB_STATUS_ERROR_MEMORY_ALLOCATION;
                document->declarations = metadata;
                document->declaration_capacity = capacity;
            }
            document->declarations[document->declaration_count++] = (YLXDeclarationMetadata){
                lxb_css_rule_declaration(decl_rule), source_order, style->selector
            };
        }
    }
    return LXB_STATUS_OK;
}

static const YLXDeclarationMetadata *ylx_metadata(const YLXDocument *document,
                                                  const lxb_css_rule_declaration_t *declaration)
{
    for (size_t index = 0; index < document->declaration_count; index++) {
        if (document->declarations[index].declaration == declaration) {
            return &document->declarations[index];
        }
    }
    return NULL;
}

/* Lexbor 3.0.0's list-append and stylesheet-apply helpers discard allocation
   failures. Use the same selector engine and cascade primitive directly, and
   propagate each status. Remove this adapter when upstream propagates errors. */
static lxb_status_t ylx_append_list(lxb_dom_element_t *element,
                                    lxb_css_rule_declaration_list_t *list,
                                    lxb_css_selector_specificity_t specificity)
{
    if (list == NULL) return LXB_STATUS_OK;
    for (lxb_css_rule_t *rule = list->first; rule != NULL; rule = rule->next) {
        if (rule->type != LXB_CSS_RULE_DECLARATION) continue;
        lxb_css_rule_declaration_t *declaration = lxb_css_rule_declaration(rule);
        /* Lexbor retains invalid known-property tokens as __UNDEF for diagnostics;
           they are not declarations eligible for the cascade. */
        if (declaration->type == LXB_CSS_PROPERTY__UNDEF) continue;
        lxb_status_t status = lxb_dom_element_style_append(element, declaration, specificity);
        if (status != LXB_STATUS_OK) return status;
    }
    return LXB_STATUS_OK;
}

static lxb_status_t ylx_attach_match(lxb_dom_node_t *node,
                                     lxb_css_selector_specificity_t specificity, void *context)
{
    return ylx_append_list(lxb_dom_interface_element(node),
        ((lxb_css_rule_style_t *) context)->declarations, specificity);
}

static lxb_status_t ylx_initialize_inline_styles(YLXDocument *document, lxb_dom_node_t *node)
{
    for (lxb_dom_node_t *current = node; current != NULL; current = current->next) {
        if (current->type == LXB_DOM_NODE_TYPE_ELEMENT) {
            lxb_dom_element_t *element = lxb_dom_interface_element(current);
            const lxb_dom_attr_t *attribute = lxb_dom_element_attr_by_id(element, LXB_DOM_ATTR_STYLE);
            if (attribute != NULL && attribute->value != NULL && attribute->value->length != 0) {
                lxb_dom_document_css_t *css = current->owner_document->css;
                css->parser->memory = css->memory;
                lxb_css_rule_declaration_list_t *list = lxb_css_declaration_list_parse(css->parser,
                    attribute->value->data, attribute->value->length);
                if (list == NULL) return css->parser->status;
                element->list = list;
                for (lxb_css_rule_t *rule = list->first; rule != NULL; rule = rule->next) {
                    if (rule->type == LXB_CSS_RULE_DECLARATION
                        && lxb_css_rule_declaration(rule)->type == LXB_CSS_PROPERTY__UNDEF) {
                        document->unparsed_declaration_count += 1;
                    }
                }
                lxb_status_t status = ylx_append_list(element, element->list,
                                                       lxb_css_selector_sp_up_s(0));
                if (status != LXB_STATUS_OK) return status;
            }
        }
        if (current->first_child != NULL) {
            lxb_status_t status = ylx_initialize_inline_styles(document, current->first_child);
            if (status != LXB_STATUS_OK) return status;
        }
    }
    return LXB_STATUS_OK;
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
            if (!context->text(node_id, parent_id, ylx_bytes(text->data.data, text->data.length), context->context)) return 0;
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
    (void) element;
    /* Lexbor 3.0.0 ignores style_walk's with_weak argument. */
    if (is_weak) return LXB_STATUS_OK;
    YLXWalkContext *context = ctx;
    YLXBuffer name = {0};
    YLXBuffer value = {0};
    YLXBuffer selector = {0};
    const YLXDeclarationMetadata *metadata = ylx_metadata(context->document, declaration);
    lxb_status_t status = lxb_css_rule_declaration_serialize_name(declaration, ylx_buffer_append, &name);
    if (status == LXB_STATUS_OK) {
        status = declaration->type == LXB_CSS_PROPERTY__CUSTOM
            ? lxb_css_property__custom_serialize_value(declaration->u.custom, ylx_buffer_append, &value)
            : lxb_css_property_serialize(declaration->u.user, declaration->type, ylx_buffer_append, &value);
    }
    if (status == LXB_STATUS_OK && metadata != NULL) {
        status = lxb_css_selector_serialize_list_chain(metadata->selector, ylx_buffer_append, &selector);
    }
    if (status == LXB_STATUS_OK) {
        YLXWinningDeclaration snapshot = {
            ylx_bytes(name.data, name.length), ylx_bytes(value.data, value.length),
            ylx_bytes(selector.data, selector.length), specificity,
            metadata == NULL ? 0 : metadata->source_order,
            (uint8_t) (lxb_css_selector_sp_s(specificity) ? 1 : 0),
            declaration->important ? 1 : 0
        };
        if (!context->declaration(context->next_id, &snapshot, context->context)) status = LXB_STATUS_STOP;
    }
    free(name.data); free(value.data); free(selector.data);
    return status;
}

static lxb_status_t ylx_walk_declarations(lxb_dom_node_t *node, YLXWalkContext *context)
{
    for (lxb_dom_node_t *current = node; current != NULL; current = current->next) {
        context->next_id += 1;
        if (current->type == LXB_DOM_NODE_TYPE_ELEMENT) {
            lxb_dom_element_t *element = lxb_dom_interface_element(current);
            if (element->style != NULL) {
                lxb_status_t status = lxb_dom_element_style_walk(element, ylx_walk_declaration, context, false);
                if (status != LXB_STATUS_OK) return status;
            }
        }
        if (current->first_child != NULL) {
            lxb_status_t status = ylx_walk_declarations(current->first_child, context);
            if (status != LXB_STATUS_OK) return status;
        }
    }
    return LXB_STATUS_OK;
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

    /* The ingestion layer supplies active stylesheets in source order. Initialize
       after HTML parsing so <style> is not silently collected a second time. */
    parse_status = lxb_style_init(document->html);
    if (parse_status == LXB_STATUS_OK) {
        document->style_initialized = true;
        parse_status = ylx_initialize_inline_styles(document, lxb_dom_interface_node(document->html));
    }
    if (parse_status != LXB_STATUS_OK) {
        if (status != NULL) *status = ylx_status(parse_status);
        if (document->style_initialized) lxb_style_destroy(document->html);
        lxb_html_document_destroy(document->html);
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
    if (document == NULL || (bytes == NULL && length != 0)) return YLX_STATUS_INVALID_ARGUMENT;
    if (document->failure != YLX_STATUS_OK) return document->failure;
    if (length == 0) return YLX_STATUS_OK;
    lxb_dom_document_t *dom = lxb_dom_interface_document(document->html);
    lxb_css_parser_t *parser = lxb_css_parser_create();
    if (parser == NULL) return YLX_STATUS_OUT_OF_MEMORY;
    lxb_status_t status = lxb_css_parser_init(parser, NULL);
    if (status == LXB_STATUS_OK) status = lxb_css_parser_selectors_init(parser);
    lxb_css_stylesheet_t *sheet = NULL;
    if (status == LXB_STATUS_OK) {
        sheet = lxb_css_stylesheet_create(dom->css->memory);
        status = sheet == NULL ? LXB_STATUS_ERROR_MEMORY_ALLOCATION
            : lxb_css_stylesheet_parse(sheet, parser, (const lxb_char_t *) bytes, length);
    }
    if (status == LXB_STATUS_OK) {
        status = ylx_record_rule_list(document, lxb_css_rule_list(sheet->root), source_order);
    }
    if (status == LXB_STATUS_OK) {
        status = lxb_dom_document_stylesheet_add(dom, sheet);
    }
    if (status == LXB_STATUS_OK) {
        lxb_css_rule_list_t *list = lxb_css_rule_list(sheet->root);
        for (lxb_css_rule_t *rule = list->first; rule != NULL; rule = rule->next) {
            if (rule->type != LXB_CSS_RULE_STYLE) continue;
            lxb_css_rule_style_t *style = lxb_css_rule_style(rule);
            status = lxb_selectors_find(dom->css->selectors, lxb_dom_interface_node(dom),
                style->selector, ylx_attach_match, style);
            if (status != LXB_STATUS_OK) break;
        }
    }
    /* All stylesheet storage belongs to the document CSS arena. On a partial
       attachment failure, prevent consumers from accepting a partial cascade. */
    document->failure = ylx_status(status);
    lxb_css_parser_destroy(parser, true);
    return document->failure;
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
    if (document->failure != YLX_STATUS_OK) return document->failure;
    YLXWalkContext walk = { document, NULL, NULL, NULL, declaration, context, 0 };
    return ylx_status(ylx_walk_declarations(lxb_dom_interface_node(document->html), &walk));
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

size_t
ylx_document_unparsed_declaration_count(const YLXDocument *document)
{
    return document == NULL ? 0 : document->unparsed_declaration_count;
}

size_t
ylx_document_unsupported_rule_count(const YLXDocument *document)
{
    return document == NULL ? 0 : document->unsupported_rule_count;
}
