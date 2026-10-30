"""Execute staged BASIC seats; container and human seats retain the WebSocket protocol."""

import asyncio
import json
import os
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

from .artifacts import file_path, read_json, write_json


class FileSeat(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["policy"]
    slot: int = Field(ge=0)
    file_uri: str
    content_hash: str
    size_bytes: int = Field(ge=0)
    log_uri: str
    artifact_uri: str
    annotations_uri: str | None = None


class SocketSeat(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["container", "human"]
    slot: int = Field(ge=0)


class Seats(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_: Literal["coworld-play-seats/2"] = Field(alias="schema")
    seats: list[Annotated[FileSeat | SocketSeat, Field(discriminator="kind")]]
    player_status_uri: str


class WorkerReady(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["ready"] = "ready"


class WorkerAction(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    kind: Literal["action"]
    action: list[int] = Field(min_length=5, max_length=5)


class PolicyFault(BaseModel):
    kind: Literal["player_error"] = "player_error"
    slot: int = Field(serialization_alias="failed_policy_index")
    message: str


class FilePlayers:
    def __init__(self, seats: Seats):
        self.files = {seat.slot: seat for seat in seats.seats if isinstance(seat, FileSeat)}
        self.status_uri = seats.player_status_uri
        self.processes: dict[int, asyncio.subprocess.Process] = {}
        self.log_tasks: list[asyncio.Task] = []
        self.failed_slots: set[int] = set()
        self.closed = False

    async def capture_log(self, seat: FileSeat, stream: asyncio.StreamReader):
        remaining = 10 * 1024 * 1024
        with file_path(seat.log_uri).open("wb") as log:
            while chunk := await stream.read(4096):
                log.write(chunk[:remaining])
                remaining = max(0, remaining - len(chunk))

    async def start(self) -> WorkerReady | PolicyFault:
        for seat in self.files.values():
            file_path(seat.log_uri).parent.mkdir(parents=True, exist_ok=True)
            file_path(seat.log_uri).touch()
        for seat in self.files.values():
            proc = await asyncio.create_subprocess_exec(
                "prlimit",
                "--as=268435456",
                "--cpu=120",
                "--core=0",
                "--",
                os.environ.get("GENERALS_BASIC_WORKER", "/usr/local/bin/generals-basic"),
                str(file_path(seat.file_uri)),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env={},
                limit=4096,
            )
            self.processes[seat.slot] = proc
            self.log_tasks.append(asyncio.create_task(self.capture_log(seat, proc.stderr)))
            reply = await proc.stdout.readline()
            if not reply:
                self.failed_slots.add(seat.slot)
                return PolicyFault(slot=seat.slot, message="BASIC compilation failed")
            WorkerReady.model_validate_json(reply)
        return WorkerReady()

    async def act(self, slot: int, observation: dict) -> WorkerAction | PolicyFault:
        proc = self.processes[slot]
        if proc.returncode is not None:
            self.failed_slots.add(slot)
            return PolicyFault(slot=slot, message="BASIC worker exited before its next decision")
        proc.stdin.write(json.dumps(observation, separators=(",", ":")).encode() + b"\n")
        await proc.stdin.drain()
        reply = await proc.stdout.readline()
        if not reply:
            self.failed_slots.add(slot)
            return PolicyFault(slot=slot, message="BASIC execution failed or exceeded its budget")
        return WorkerAction.model_validate_json(reply)

    async def close(self):
        if self.closed:
            return
        for proc in self.processes.values():
            if proc.returncode is None:
                proc.stdin.close()
        for proc in self.processes.values():
            await proc.wait()
        await asyncio.gather(*self.log_tasks)
        write_json(
            self.status_uri,
            {
                "schema_version": "1",
                "players": [
                    {
                        "slot": slot,
                        "state": "exited",
                        "exit_code": proc.returncode,
                        "reason": "BASIC failure" if slot in self.failed_slots else "Completed",
                    }
                    for slot, proc in self.processes.items()
                ],
            },
        )
        self.closed = True


def load_file_players(player_count: int) -> FilePlayers | None:
    if "COGAME_PLAYER_SEATS_URI" not in os.environ:
        return None
    seats = Seats.model_validate(read_json(os.environ["COGAME_PLAYER_SEATS_URI"]))
    if sorted(seat.slot for seat in seats.seats) != list(range(player_count)):
        raise ValueError("player roster must contain each configured slot exactly once")
    return FilePlayers(seats)
