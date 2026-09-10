#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Startup/deployment is serialized by the host before it accepts any sessions.
bool QRimeStart(const char* frameworks, const char* shared, const char* user, bool deploy);
void QRimeStop(void);
const char* QRimeError(void);
const char* QRimeVersion(void);
uintptr_t QRimeCreateSession(void);
void QRimeDestroySession(uintptr_t session);
bool QRimeProcess(uintptr_t session, int key, int modifiers);
bool QRimeSelect(uintptr_t session, size_t index);
bool QRimeSchema(uintptr_t session, const char* schema);
void QRimeClear(uintptr_t session);
bool QRimeCommitComposition(uintptr_t session);
const char* QRimeTakeCommit(uintptr_t session);
void QRimeSetOption(uintptr_t session, const char* name, bool value);
bool QRimeGetOption(uintptr_t session, const char* name);

// Snapshot strings remain valid until the next Read. Host copies them immediately.
bool QRimeRead(uintptr_t session);
const char* QRimePreedit(void);
const char* QRimeInput(void);
int QRimeCursorBytes(void);
int QRimeHighlighted(void);
int QRimePage(void);
bool QRimeLastPage(void);
size_t QRimeCandidateCount(void);
const char* QRimeCandidateText(size_t index);
const char* QRimeCandidateComment(size_t index);

#ifdef __cplusplus
}
#endif
