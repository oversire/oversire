# Chat stream fixtures

The SSE bodies of one streamed turn, for each API format. ScriptedHTTP plays them in small chunks.

These files are written by hand from the documented stream formats (Anthropic Messages streaming and OpenAI Chat Completions streaming). They are not recordings. The live test (`OVERSIRE_LIVE=1`, `APIKeyChatLiveTests`) checks the real APIs.

The tests use the tool `echo` of `ChatEngineConformance`.
