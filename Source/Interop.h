#ifndef CODEX_T3_INTEROP_H
#define CODEX_T3_INTEROP_H
#include <zlib.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <bsm/libbsm.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// One bounded JSON message; no descriptors, shared memory or file access.
typedef struct {
    mach_msg_header_t header;
    uint32_t length;
    unsigned char payload[];
} T3MachWire;
#define T3_MESSAGE_ID 0x5433
#define T3_MAX_PAYLOAD 65536
static inline size_t t3_mach_aligned(size_t size) { return (size + 3) & ~(size_t)3; }
static inline void t3_mach_release(mach_port_t port) {
    if (MACH_PORT_VALID(port)) mach_port_deallocate(mach_task_self(), port);
}
static inline void t3_mach_destroy(mach_port_t port) {
    if (MACH_PORT_VALID(port)) mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
}
// Public bootstrap registration permits an on-demand service owned by the app;
// no persistent launch agent is installed. Lookups remain sandbox-entitled.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline kern_return_t t3_mach_register(const char *name, mach_port_t *port) {
    mach_port_t existing = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, name, &existing) == KERN_SUCCESS) {
        t3_mach_release(existing);
        return BOOTSTRAP_SERVICE_ACTIVE;
    }
    kern_return_t result = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, port);
    if (result != KERN_SUCCESS) return result;
    result = mach_port_insert_right(mach_task_self(), *port, *port, MACH_MSG_TYPE_MAKE_SEND);
    if (result == KERN_SUCCESS) {
        result = bootstrap_register(bootstrap_port, (char *)name, *port);
        t3_mach_release(*port); // Registration holds its own send right.
    }
    if (result != KERN_SUCCESS) {
        t3_mach_destroy(*port);
        *port = MACH_PORT_NULL;
    }
    return result;
}
static inline void t3_mach_unregister(const char *name, mach_port_t port) {
    kern_return_t result = bootstrap_register(bootstrap_port, (char *)name, MACH_PORT_NULL);
    (void)result;
    t3_mach_destroy(port);
}
#pragma clang diagnostic pop
static inline kern_return_t t3_mach_lookup(const char *name, mach_port_t *port) {
    return bootstrap_look_up(bootstrap_port, name, port);
}
static inline kern_return_t t3_mach_reply_port(mach_port_t *port) {
    return mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, port);
}
// A reply consumes its send-once right on success OR failure.
static inline kern_return_t t3_mach_send(mach_port_t destination, mach_port_t reply,
                                       const void *payload, uint32_t length, int is_reply) {
    if (length > T3_MAX_PAYLOAD) {
        if (is_reply) t3_mach_release(destination);
        return KERN_INVALID_ARGUMENT;
    }
    size_t size = offsetof(T3MachWire, payload) + t3_mach_aligned(length);
    T3MachWire *wire = calloc(1, size);
    if (!wire) {
        if (is_reply) t3_mach_release(destination);
        return KERN_RESOURCE_SHORTAGE;
    }
    wire->header.msgh_bits = is_reply ? MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0) :
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    wire->header.msgh_size = (mach_msg_size_t)size;
    wire->header.msgh_remote_port = destination;
    wire->header.msgh_local_port = reply;
    wire->header.msgh_id = T3_MESSAGE_ID;
    wire->length = length;
    if (length) memcpy(wire->payload, payload, length);
    kern_return_t result = mach_msg(&wire->header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                    wire->header.msgh_size, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
    if (is_reply && result != KERN_SUCCESS) t3_mach_release(destination);
    free(wire);
    return result;
}
static inline kern_return_t t3_mach_receive(mach_port_t port, void *payload, uint32_t maximum,
                                           uint32_t timeout_ms, int expects_reply_port,
                                           uint32_t *length, mach_port_t *reply, audit_token_t *audit) {
    if (maximum > T3_MAX_PAYLOAD) return KERN_INVALID_ARGUMENT;
    *length = 0; *reply = MACH_PORT_NULL;
    size_t capacity = offsetof(T3MachWire, payload) + t3_mach_aligned(maximum) + MAX_TRAILER_SIZE;
    T3MachWire *wire = calloc(1, capacity);
    if (!wire) return KERN_RESOURCE_SHORTAGE;
    // Without MACH_RCV_LARGE, an oversized message is discarded, allowing the
    // listener to continue servicing subsequent clients.
    kern_return_t result = mach_msg(&wire->header,
        MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
        MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT), 0, (mach_msg_size_t)capacity,
        port, timeout_ms, MACH_PORT_NULL);
    if (result != KERN_SUCCESS) { free(wire); return result; }
    size_t size = wire->header.msgh_size;
    size_t trailer_offset = t3_mach_aligned(size);
    int valid = !(wire->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
        wire->header.msgh_id == T3_MESSAGE_ID && size >= offsetof(T3MachWire, payload) &&
        size <= offsetof(T3MachWire, payload) + t3_mach_aligned(maximum) &&
        wire->length <= maximum &&
        size == offsetof(T3MachWire, payload) + t3_mach_aligned(wire->length) &&
        trailer_offset + sizeof(mach_msg_audit_trailer_t) <= capacity;
    if (expects_reply_port) {
        valid = valid && MACH_PORT_VALID(wire->header.msgh_remote_port) &&
            MACH_MSGH_BITS_REMOTE(wire->header.msgh_bits) == MACH_MSG_TYPE_PORT_SEND_ONCE;
    } else {
        valid = valid && wire->header.msgh_remote_port == MACH_PORT_NULL &&
            MACH_MSGH_BITS_REMOTE(wire->header.msgh_bits) == 0;
    }
    if (valid) {
        mach_msg_audit_trailer_t *trailer = (mach_msg_audit_trailer_t *)((char *)wire + trailer_offset);
        valid = trailer->msgh_trailer_type == MACH_MSG_TRAILER_FORMAT_0 &&
            trailer->msgh_trailer_size >= sizeof(mach_msg_audit_trailer_t);
        if (valid) *audit = trailer->msgh_audit;
    }
    if (!valid) {
        mach_msg_destroy(&wire->header);
        free(wire);
        return KERN_INVALID_ARGUMENT;
    }
    *length = wire->length;
    *reply = wire->header.msgh_remote_port;
    if (*length) memcpy(payload, wire->payload, *length);
    free(wire);
    return KERN_SUCCESS;
}
static inline uid_t t3_mach_uid(audit_token_t token) { return audit_token_to_euid(token); }
#endif
