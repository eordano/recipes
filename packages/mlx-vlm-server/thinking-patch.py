"""Patch mlx_vlm/server.py to separate <think>...</think> into reasoning_content."""
import re, sys

path = "mlx_vlm/server.py"
src = open(path).read()

# ---------------------------------------------------------------------------
# 1. Insert ThinkingTagParser + split_thinking after the imports, before the
#    FastAPI app instantiation.
# ---------------------------------------------------------------------------
PARSER_CODE = '''
# ---------------------------------------------------------------------------
# Reasoning / thinking-tag parser
# Handles <think>...</think> blocks produced by reasoning models (Qwen3, etc.)
# Splits them into a separate reasoning_content field on the response.
#
# Handles two scenarios:
#   1. Model outputs <think>...</think>content  (explicit open tag)
#   2. Chat template already opened <think>, so model outputs reasoning
#      text then </think>content  (implicit start-inside-think)
# ---------------------------------------------------------------------------

THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"


def _tail_could_start(buf, tag):
    """Check if any suffix of buf is a prefix of tag."""
    for i in range(1, min(len(buf), len(tag)) + 1):
        if tag.startswith(buf[-i:]):
            return i
    return 0


class ThinkingTagParser:
    """Streaming state machine that separates <think>...</think> from content.

    While undecided, all text is buffered (reasoning is hidden from the user
    anyway, so the latency cost is invisible).  Once the first tag is found:
      - </think> first → everything before it was reasoning
      - <think> first  → everything before it was content
      - finalize without any tag → everything is content (non-thinking model)
    After the decision, text is streamed through normal tag-splitting.
    """

    def __init__(self):
        self.inside_think = False
        self.buffer = ""
        self.thinking_text = ""
        self._decided = False

    def feed(self, text: str):
        """Feed a chunk of text.  Returns (content_delta, reasoning_delta)."""
        self.buffer += text
        content_out = ""
        reasoning_out = ""

        if not self._decided:
            open_idx = self.buffer.find(THINK_OPEN)
            close_idx = self.buffer.find(THINK_CLOSE)

            if close_idx != -1 and (open_idx == -1 or close_idx < open_idx):
                # </think> first → we started inside think
                self._decided = True
                before = self.buffer[:close_idx]
                reasoning_out += before
                self.thinking_text += before
                self.buffer = self.buffer[close_idx + len(THINK_CLOSE):]
                self.inside_think = False  # now outside

            elif open_idx != -1:
                # <think> first → normal mode
                self._decided = True
                content_out += self.buffer[:open_idx]
                self.buffer = self.buffer[open_idx + len(THINK_OPEN):]
                self.inside_think = True  # now inside <think>

            else:
                # No full tag yet — keep buffering
                return "", ""

        # Normal tag-splitting (post-decision)
        while self.buffer:
            tag = THINK_CLOSE if self.inside_think else THINK_OPEN
            idx = self.buffer.find(tag)

            if idx != -1:
                before = self.buffer[:idx]
                if self.inside_think:
                    reasoning_out += before
                    self.thinking_text += before
                else:
                    content_out += before
                self.buffer = self.buffer[idx + len(tag):]
                self.inside_think = not self.inside_think
            else:
                tail = _tail_could_start(self.buffer, tag)
                if tail:
                    safe = self.buffer[:-tail]
                    if safe:
                        if self.inside_think:
                            reasoning_out += safe
                            self.thinking_text += safe
                        else:
                            content_out += safe
                    self.buffer = self.buffer[-tail:]
                    break
                else:
                    if self.inside_think:
                        reasoning_out += self.buffer
                        self.thinking_text += self.buffer
                    else:
                        content_out += self.buffer
                    self.buffer = ""

        return content_out, reasoning_out

    def finalize(self):
        """Flush remaining buffer."""
        leftover = self.buffer
        self.buffer = ""
        if not self._decided:
            # Never saw any tags — not a thinking model, emit all as content
            return leftover, ""
        if self.inside_think:
            self.thinking_text += leftover
            return "", leftover
        return leftover, ""


def split_thinking(text: str):
    """Split a complete text into (content, reasoning_content | None)."""
    parser = ThinkingTagParser()
    content, reasoning = parser.feed(text)
    c2, r2 = parser.finalize()
    content += c2
    reasoning += r2
    return content.strip(), reasoning.strip() or None

'''

# Insert before the `app = FastAPI(` line
assert "app = FastAPI(" in src, "Cannot find 'app = FastAPI(' in server.py"
src = src.replace("app = FastAPI(", PARSER_CODE + "app = FastAPI(", 1)

# ---------------------------------------------------------------------------
# 2. Add reasoning_content field to ChatMessage
# ---------------------------------------------------------------------------
old_chatmsg = '''class ChatMessage(FlexibleBaseModel):
    role: Literal["user", "assistant", "system", "developer", "tool"] = Field(
        ...,
        description="Role of the message sender (e.g., 'system', 'user', 'assistant').",
    )
    content: Optional[
        Union[
            str,
            ResponseInputMessageContentListParam,
            ResponseOutputMessageContentList,
        ]
    ] = Field(None, description="Content of the message.")
    tool_calls: List = []'''

new_chatmsg = '''class ChatMessage(FlexibleBaseModel):
    role: Literal["user", "assistant", "system", "developer", "tool"] = Field(
        ...,
        description="Role of the message sender (e.g., 'system', 'user', 'assistant').",
    )
    content: Optional[
        Union[
            str,
            ResponseInputMessageContentListParam,
            ResponseOutputMessageContentList,
        ]
    ] = Field(None, description="Content of the message.")
    reasoning_content: Optional[str] = Field(None, description="Reasoning content from thinking models.")
    tool_calls: List = []'''

assert old_chatmsg in src, "Cannot find ChatMessage class in server.py"
src = src.replace(old_chatmsg, new_chatmsg, 1)

# ---------------------------------------------------------------------------
# 3. Patch non-streaming response to split thinking
# ---------------------------------------------------------------------------
old_nonstream = '''                choices = [
                    ChatChoice(
                        finish_reason="stop",
                        message=ChatMessage(
                            role="assistant",
                            content=tool_calls["remaining_text"],
                            tool_calls=tool_calls["calls"],
                        ),
                    )
                ]'''

new_nonstream = '''                _content, _reasoning = split_thinking(tool_calls["remaining_text"])
                choices = [
                    ChatChoice(
                        finish_reason="stop",
                        message=ChatMessage(
                            role="assistant",
                            content=_content,
                            reasoning_content=_reasoning,
                            tool_calls=tool_calls["calls"],
                        ),
                    )
                ]'''

assert old_nonstream in src, "Cannot find non-streaming choices block in server.py"
src = src.replace(old_nonstream, new_nonstream, 1)

# ---------------------------------------------------------------------------
# 4. Patch streaming response to filter through ThinkingTagParser
# ---------------------------------------------------------------------------
# a) instantiate the parser before the loop

old_stream_setup = '''            async def stream_generator():
                token_iterator = None
                try:
                    # Use stream_generate from utils
                    token_iterator = stream_generate('''

new_stream_setup = '''            async def stream_generator():
                token_iterator = None
                _think_parser = ThinkingTagParser()
                try:
                    # Use stream_generate from utils
                    token_iterator = stream_generate('''

assert old_stream_setup in src, "Cannot find stream_generator setup in server.py"
src = src.replace(old_stream_setup, new_stream_setup, 1)

# b) route each chunk.text through the parser

old_stream_chunk = '''                        choices = [
                            ChatStreamChoice(
                                delta=ChatMessage(role="assistant", content=chunk.text)
                            )
                        ]
                        chunk_data = ChatStreamChunk(
                            id=request_id,
                            created=int(time.time()),
                            model=request.model,
                            usage=usage_stats,
                            choices=choices,
                        )

                        yield f"data: {chunk_data.model_dump_json()}\\n\\n"'''

new_stream_chunk = '''                        _c_delta, _r_delta = _think_parser.feed(chunk.text)
                        if _c_delta or _r_delta:
                            choices = [
                                ChatStreamChoice(
                                    delta=ChatMessage(
                                        role="assistant",
                                        content=_c_delta or "",
                                        reasoning_content=_r_delta or None,
                                    )
                                )
                            ]
                            chunk_data = ChatStreamChunk(
                                id=request_id,
                                created=int(time.time()),
                                model=request.model,
                                usage=usage_stats,
                                choices=choices,
                            )

                            yield f"data: {chunk_data.model_dump_json()}\\n\\n"'''

assert old_stream_chunk in src, "Cannot find streaming chunk block in server.py"
src = src.replace(old_stream_chunk, new_stream_chunk, 1)

# c) flush before the stop signal

old_stream_end = '''                    # Signal stream end
                    choices = [
                        ChatStreamChoice(
                            finish_reason="stop",
                            delta=ChatMessage(
                                role="assistant",
                                content="",
                                tool_calls=tool_calls["calls"],
                            ),
                        )
                    ]'''

new_stream_end = '''                    # Flush any remaining buffered text
                    _c_final, _r_final = _think_parser.finalize()
                    if _c_final or _r_final:
                        choices = [
                            ChatStreamChoice(
                                delta=ChatMessage(
                                    role="assistant",
                                    content=_c_final or "",
                                    reasoning_content=_r_final or None,
                                )
                            )
                        ]
                        chunk_data = ChatStreamChunk(
                            id=request_id,
                            created=int(time.time()),
                            model=request.model,
                            usage=usage_stats,
                            choices=choices,
                        )
                        yield f"data: {chunk_data.model_dump_json()}\\n\\n"

                    # Signal stream end
                    choices = [
                        ChatStreamChoice(
                            finish_reason="stop",
                            delta=ChatMessage(
                                role="assistant",
                                content="",
                                tool_calls=tool_calls["calls"],
                            ),
                        )
                    ]'''

assert old_stream_end in src, "Cannot find stream end block in server.py"
src = src.replace(old_stream_end, new_stream_end, 1)

open(path, "w").write(src)
print("server.py patched successfully for thinking-tag support")

# ---------------------------------------------------------------------------
# 6. Patch prompt_utils.py: load chat_template from the base (non-quantized)
#    model's tokenizer_config.json when the quantized model is missing it.
#    Also pass enable_thinking=True so the template appends <think>\n.
# ---------------------------------------------------------------------------
pu_path = "mlx_vlm/prompt_utils.py"
pu_src = open(pu_path).read()

# Inject a helper that fetches the chat template from the base model repo
# on first use, caching it for subsequent calls.
TEMPLATE_HELPER = '''
import os as _os

_CHAT_TEMPLATE_CACHE = {}

def _ensure_chat_template(processor):
    """If the processor/tokenizer has no chat_template, try to load one from
    the base (non-quantized) model repo.  Many MLX community quantizations
    strip the chat_template from tokenizer_config.json.

    Looks for tokenizer_config.json in the model directory first (offline),
    then falls back to downloading from huggingface.co.
    """
    tokenizer = getattr(processor, "tokenizer", processor)
    if getattr(tokenizer, "chat_template", None) is not None:
        return  # already has one

    model_name = getattr(tokenizer, "name_or_path", "") or ""
    if model_name in _CHAT_TEMPLATE_CACHE:
        tokenizer.chat_template = _CHAT_TEMPLATE_CACHE[model_name]
        return

    # Try loading from a sibling tokenizer_config.json in the model dir
    import json as _json
    model_dir = getattr(tokenizer, "name_or_path", None)
    if model_dir:
        cfg_path = _os.path.join(model_dir, "tokenizer_config.json")
        if _os.path.isfile(cfg_path):
            try:
                with open(cfg_path) as f:
                    cfg = _json.load(f)
                if "chat_template" in cfg:
                    tokenizer.chat_template = cfg["chat_template"]
                    _CHAT_TEMPLATE_CACHE[model_name] = cfg["chat_template"]
                    return
            except Exception:
                pass

    # For known model families, try to fetch from the base model repo
    _BASE_REPOS = {
        "qwen3_5_moe": "Qwen/Qwen3.5-35B-A3B",
        "qwen3_moe": "Qwen/Qwen3-30B-A3B",
        "qwen3": "Qwen/Qwen3-8B",
    }

    model_type = None
    # Try to infer model_type from the model config
    for attr in ("config", "model_config"):
        cfg_obj = getattr(processor, attr, None) or getattr(tokenizer, attr, None)
        if cfg_obj:
            model_type = getattr(cfg_obj, "model_type", None)
            if model_type is None and isinstance(cfg_obj, dict):
                model_type = cfg_obj.get("model_type")
            if model_type:
                break

    if not model_type:
        return

    base_repo = _BASE_REPOS.get(model_type)
    if not base_repo:
        return

    try:
        from urllib.request import urlopen
        url = f"https://huggingface.co/{base_repo}/raw/main/tokenizer_config.json"
        data = _json.loads(urlopen(url, timeout=10).read())
        template = data.get("chat_template")
        if template:
            tokenizer.chat_template = template
            _CHAT_TEMPLATE_CACHE[model_name] = template
            print(f"[thinking-patch] Loaded chat_template from {base_repo}")
    except Exception as e:
        print(f"[thinking-patch] Could not fetch chat_template from {base_repo}: {e}")

'''

# Insert the helper before the get_chat_template function
assert "def get_chat_template(" in pu_src, "Cannot find get_chat_template in prompt_utils.py"
pu_src = pu_src.replace("def get_chat_template(", TEMPLATE_HELPER + "def get_chat_template(", 1)

# Now inject a call to _ensure_chat_template at the start of get_chat_template.
old_template_check = '''    try:
        template_processor = None
        if (
            processor is not None
            and hasattr(processor, "apply_chat_template")
            and (
                chat_template_override is not None
                or getattr(processor, "chat_template", None) is not None
            )
        ):
            template_processor = processor'''

new_template_check = '''    # Ensure the processor has a chat_template (may load from base model)
    if processor is not None:
        _ensure_chat_template(processor)

    try:
        template_processor = None
        if (
            processor is not None
            and hasattr(processor, "apply_chat_template")
            and (
                chat_template_override is not None
                or getattr(processor, "chat_template", None) is not None
            )
        ):
            template_processor = processor'''

assert old_template_check in pu_src, "Cannot find template_processor detection in prompt_utils.py"
pu_src = pu_src.replace(old_template_check, new_template_check, 1)

open(pu_path, "w").write(pu_src)
print("prompt_utils.py patched successfully for chat template loading")
