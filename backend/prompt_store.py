"""Immutable editing rules stored separately from the application and runtime.

The primary file is the commit record; the mirror is a recovery copy. Mutation
never edits an existing version, and a failed commit never changes the in-memory
selection. Invalid files are preserved before a recoverable copy is repaired.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import threading
import uuid


MAX_PROFILE_BYTES = 128 * 1024
DRAFT_FIELDS = {"name", "note", "system_prompt", "user_prefix", "examples"}


class PromptValidationError(ValueError):
    pass


class PromptStoreError(RuntimeError):
    pass


def json_bytes(value) -> bytes:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                          allow_nan=False).encode("utf-8")
    except (TypeError, ValueError, UnicodeError, RecursionError) as exc:
        raise PromptValidationError("规则须包含有效的 UTF-8 JSON 文本。") from exc


def validate_draft(value) -> dict:
    if not isinstance(value, dict) or set(value) != DRAFT_FIELDS:
        raise PromptValidationError("规则须包含 name、note、system_prompt、user_prefix 和 examples。")
    if len(json_bytes(value)) > MAX_PROFILE_BYTES:
        raise PromptValidationError("单个规则版本超过 128 KiB，请缩短内容后重试。")
    if any(not isinstance(value[key], str) for key in DRAFT_FIELDS - {"examples"}):
        raise PromptValidationError("名称、说明和提示词须为文本。")
    if not value["name"].strip() or not value["system_prompt"].strip():
        raise PromptValidationError("版本名称和润色规则不能为空。")
    examples = value["examples"]
    if not isinstance(examples, list) or any(
        not isinstance(item, dict) or set(item) != {"source", "edited"}
        or not isinstance(item["source"], str) or not isinstance(item["edited"], str)
        for item in examples
    ):
        raise PromptValidationError("每个示例须包含文本 source 和 edited。")
    # Preserve prompt whitespace exactly; it is part of the model input.
    return {**value, "name": value["name"].strip(), "examples": [dict(item) for item in examples]}


def content_hash(system_prompt: str, user_prefix: str, examples) -> str:
    content = {"system_prompt": system_prompt, "user_prefix": user_prefix,
               "examples": [{"source": source, "edited": edited} for source, edited in examples]}
    return hashlib.sha256(json_bytes(content)).hexdigest()


@dataclass(frozen=True)
class PromptVersion:
    id: str
    name: str
    note: str
    created_at: str
    model_id: str | None
    system_prompt: str
    user_prefix: str
    examples: tuple[tuple[str, str], ...]
    content_sha256: str
    origin: str

    @classmethod
    def create(cls, draft, model_id, *, version_id=None, origin="user", created_at=None):
        value = validate_draft(draft)
        pairs = tuple((item["source"], item["edited"]) for item in value["examples"])
        return cls(version_id or str(uuid.uuid4()), value["name"], value["note"],
                   created_at or datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
                   model_id, value["system_prompt"], value["user_prefix"], pairs,
                   content_hash(value["system_prompt"], value["user_prefix"], pairs), origin)

    def as_dict(self):
        return {"id": self.id, "name": self.name, "note": self.note, "created_at": self.created_at,
                "model_id": self.model_id, "system_prompt": self.system_prompt,
                "user_prefix": self.user_prefix,
                "examples": [{"source": source, "edited": edited} for source, edited in self.examples],
                "content_sha256": self.content_sha256, "origin": self.origin}

    @classmethod
    def from_dict(cls, value):
        expected = DRAFT_FIELDS | {"id", "created_at", "model_id", "content_sha256", "origin"}
        if not isinstance(value, dict) or set(value) != expected:
            raise PromptValidationError("规则版本结构无法识别。")
        if any(not isinstance(value[key], str) or not value[key] for key in
               ("id", "created_at", "content_sha256", "origin")):
            raise PromptValidationError("规则版本元数据无效。")
        if value["model_id"] is not None and not isinstance(value["model_id"], str):
            raise PromptValidationError("规则模型记录无效。")
        try:
            stamp = datetime.fromisoformat(value["created_at"].replace("Z", "+00:00"))
            if stamp.tzinfo is None:
                raise ValueError()
        except ValueError as exc:
            raise PromptValidationError("规则版本时间无效。") from exc
        result = cls.create({key: value[key] for key in DRAFT_FIELDS}, value["model_id"],
                            version_id=value["id"], origin=value["origin"], created_at=value["created_at"])
        if result.content_sha256 != value["content_sha256"]:
            raise PromptValidationError("规则内容校验不一致。")
        return result


class PromptStore:
    def __init__(self, default_draft, model_id, directory: Path | None = None, *, memory_only=False):
        self.directory = None if memory_only else (directory or Path.home() / "Library/Application Support/LocalDictation")
        self.lock = threading.RLock()
        self.versions: tuple[PromptVersion, ...] = ()
        self.active_version_id: str | None = None
        self.error: str | None = None
        self.persistence_warning: str | None = None
        self.recovery_message: str | None = None
        self._pending_preservation: list[Path] = []
        seed = PromptVersion.create(default_draft, model_id, origin="builtin", version_id="builtin-current")
        if memory_only:
            self.versions, self.active_version_id = (seed,), seed.id
        else:
            self._load(seed)

    def _paths(self):
        return (self.directory / "cleanup-prompts.json", self.directory / "cleanup-prompts.backup.json")

    @staticmethod
    def _decode(raw):
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"schema_version", "active_version_id", "versions"} or value["schema_version"] != 1:
            raise PromptValidationError("规则存储版本无法识别。")
        if not isinstance(value["versions"], list) or not value["versions"]:
            raise PromptValidationError("规则版本列表为空。")
        versions = tuple(PromptVersion.from_dict(item) for item in value["versions"])
        identifiers = [item.id for item in versions]
        if len(set(identifiers)) != len(identifiers) or value["active_version_id"] not in identifiers:
            raise PromptValidationError("规则版本选择或标识无效。")
        return versions, value["active_version_id"]

    @staticmethod
    def _encode(versions, active):
        return json_bytes({"schema_version": 1, "active_version_id": active,
                           "versions": [item.as_dict() for item in versions]}) + b"\n"

    def _preserve(self, path):
        if path.exists():
            suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
            archived = path.with_name(path.name + ".preserved-" + suffix)
            # Keep the original path until a fully prepared replacement exists.
            with open(archived, "xb") as writer:
                os.chmod(archived, 0o600)
                writer.write(path.read_bytes()); writer.flush(); os.fsync(writer.fileno())

    def _load(self, seed):
        primary, backup = self._paths()
        candidates = []
        for path in (primary, backup):
            try:
                candidates.append(self._decode(path.read_bytes()))
            except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
                candidates.append(None)
        existing = primary.exists() or backup.exists()
        chosen = candidates[0] or candidates[1]
        if chosen is None and existing:
            self.error = "润色规则文件无法读取，原文件已保留；本次仅转写，不使用未知规则。"
            return
        chosen = chosen or ((seed,), seed.id)
        self.versions, self.active_version_id = chosen
        if candidates[0] == chosen and candidates[1] == chosen:
            return
        self._pending_preservation = [path for path, candidate in zip((primary, backup), candidates)
                                      if path.exists() and candidate != chosen]
        try:
            self._persist(*chosen)
            if existing:
                self.recovery_message = "已从完整副本恢复润色规则；原有异常文件已保留。"
        except OSError:
            # Read availability is independent of mirror repair. Either valid
            # copy supplies known rules; a new seed without any saved copy does
            # not become active until its first durable write has succeeded.
            if candidates[0] is not None:
                self.persistence_warning = "当前继续使用已验证的主文件；规则备份尚未修复，原文件已保留。请检查存储空间与目录权限。"
            elif candidates[1] is not None:
                self.persistence_warning = "当前使用已验证的规则备份；主文件恢复尚未写入，原文件已保留。请检查存储空间与目录权限。"
            else:
                self.error = "润色规则无法安全保存，原文件已保留；请检查数据目录权限。"

    def _persist(self, versions, active):
        if self.directory is None:
            return
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        # A prior repair can fail before the damaged source was archived. Every
        # later mutation must finish preservation before publishing new files.
        while self._pending_preservation:
            self._preserve(self._pending_preservation[0])
            self._pending_preservation.pop(0)
        primary, backup = self._paths()
        payload = self._encode(versions, active)
        temporary = []
        previous_backup = backup.read_bytes() if backup.exists() else None
        backup_published = False
        try:
            # Prepare and fsync both copies before publishing either of them.
            for destination in (backup, primary):
                path = destination.with_name(destination.name + ".tmp-" + uuid.uuid4().hex)
                temporary.append(path)
                with open(path, "xb") as writer:
                    os.chmod(path, 0o600)
                    writer.write(payload); writer.flush(); os.fsync(writer.fileno())
            os.replace(temporary[0], backup); backup_published = True
            os.replace(temporary[1], primary)
            if self.persistence_warning:
                self.persistence_warning = None
                self.recovery_message = "润色规则已完整保存到主文件与备份，存储已恢复。"
        except OSError:
            # The primary is authoritative. Best-effort restore the old mirror
            # if the primary commit failed, without touching its saved version.
            if backup_published:
                try:
                    if previous_backup is None:
                        backup.unlink(missing_ok=True)
                    else:
                        rollback = backup.with_name(backup.name + ".rollback-" + uuid.uuid4().hex)
                        temporary.append(rollback)
                        with open(rollback, "xb") as writer:
                            os.chmod(rollback, 0o600); writer.write(previous_backup)
                            writer.flush(); os.fsync(writer.fileno())
                        os.replace(rollback, backup)
                except OSError:
                    pass
            raise
        finally:
            for path in temporary:
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    # A stray temporary file is not a failed primary commit.
                    # Reporting failure here would leave memory behind disk.
                    pass

    def _require_healthy(self):
        if self.error:
            raise PromptStoreError(self.error)

    def catalog(self):
        with self.lock:
            return {"active_version_id": self.active_version_id if not self.error else None,
                    "versions": [item.as_dict() for item in reversed(self.versions)],
                    **({"prompt_store_error": self.error} if self.error else {}),
                    **({"recovery_message": self.persistence_warning or self.recovery_message}
                       if self.persistence_warning or self.recovery_message else {})}

    def resolve(self, version_id=None):
        with self.lock:
            self._require_healthy()
            target = self.active_version_id if version_id is None else version_id
            for version in self.versions:
                if version.id == target:
                    return version
            raise KeyError("所选润色规则版本不存在，请刷新后重试。")

    def create(self, draft, model_id):
        version = PromptVersion.create(draft, model_id)
        with self.lock:
            self._require_healthy()
            versions = self.versions + (version,)
            try:
                self._persist(versions, self.active_version_id)
            except OSError as exc:
                raise PromptStoreError("新规则保存失败，当前版本与原文件未被替换。") from exc
            self.versions = versions
        return version

    def activate(self, version_id):
        with self.lock:
            version = self.resolve(version_id)
            if version.id == self.active_version_id:
                return
            try:
                self._persist(self.versions, version.id)
            except OSError as exc:
                raise PromptStoreError("规则切换未保存，当前生效版本保持不变。") from exc
            self.active_version_id = version.id

    def import_versions(self, versions):
        """Import verified snapshots once, recording import time when unknown.

        Packaged manifests may omit created_at and content_sha256 together.
        Their timestamp means first import, never an invented creation date;
        repeated imports reuse it while verifying all content and metadata.
        """
        if not isinstance(versions, list):
            raise PromptValidationError("历史规则清单须为版本列表。")
        with self.lock:
            self._require_healthy()
            known = {item.id: item for item in self.versions}
            additions = []
            for value in versions:
                manifest_fields = DRAFT_FIELDS | {"id", "model_id", "origin"}
                if isinstance(value, dict) and set(value) == manifest_fields:
                    prior = known.get(value["id"]) if isinstance(value["id"], str) else None
                    draft = {key: value[key] for key in DRAFT_FIELDS}
                    candidate = PromptVersion.create(draft, value["model_id"], version_id=value["id"],
                        origin=value["origin"], created_at=prior.created_at if prior else None).as_dict()
                    # from_dict validates imported identifiers and metadata too.
                    candidate["id"] = value["id"]
                    version = PromptVersion.from_dict(candidate)
                else:
                    version = PromptVersion.from_dict(value)
                if version.id in known:
                    prior = known[version.id]
                    # Packaged descriptions may change without changing the
                    # imported rule. Keep the saved note and avoid a write for
                    # this no-op; every other field must still match exactly.
                    # from_dict above has already revalidated the payload hash.
                    if replace(version, note=prior.note) != prior:
                        raise PromptValidationError("导入版本标识冲突，未修改已有规则。")
                if version.id not in known:
                    additions.append(version); known[version.id] = version
            if additions:
                combined = self.versions + tuple(additions)
                try:
                    self._persist(combined, self.active_version_id)
                except OSError as exc:
                    raise PromptStoreError("历史规则导入未保存，现有规则保持不变。") from exc
                self.versions = combined
