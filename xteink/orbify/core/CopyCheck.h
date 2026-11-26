#pragma once
// BookSync: is the copy on the card the library file? Both sides are KOReader partial MD5s: the
// device's of the file on the card (KOReaderDocumentId), the server's the book file's fileHash in
// the catalog detail. The server's sync answers only "this copy is an older one of that file"
// (positionIncompatible); the update step compares the two before it downloads anything, so a
// copy that already is the library file is opened, not downloaded again.
namespace orbify::copy {

enum class Verdict { Same, Differs, Unknown };

// Unknown when either hash is missing or not 32 hex digits (a server that does not send it, an
// unreadable file). Case-insensitive.
Verdict compare(const char* deviceHash, const char* libraryHash);

const char* verdictName(Verdict verdict);

}  // namespace orbify::copy
