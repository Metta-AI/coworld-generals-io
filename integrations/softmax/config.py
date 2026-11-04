"""Strict runtime config and generated manifest schema."""

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, FiniteFloat, model_validator

PLAYER_NAMES = ("Red", "Blue", "Green", "Purple", "Orange", "Pink", "Teal", "Maroon")


class PlayerName(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)
    name: str = Field(min_length=1, max_length=100)


class PlayerRating(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    slot: int = Field(ge=0, le=7)
    score: FiniteFloat | None


class PlayerRatings(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    league: str
    label: str
    players: list[PlayerRating] = Field(max_length=8)


class GameConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)
    tokens: list[Annotated[str, Field(min_length=1, max_length=1024)]] = Field(min_length=2, max_length=8)
    players: list[PlayerName] = Field(min_length=2, max_length=8)
    player_ratings: PlayerRatings | None = None
    ruleset: Literal["classic", "build_castles"] = "classic"
    seed: int | None = Field(default=None, ge=0, le=2**64 - 1)
    max_turns: int = Field(default=1200, ge=1, le=50002)
    turn_timeout_seconds: float = Field(default=0.5, ge=0.05, le=1)
    tick_interval_seconds: float = Field(default=0, ge=0, le=0.5)
    player_connect_timeout_seconds: float = Field(default=180, ge=1, le=180)
    max_consecutive_timeouts: int = Field(default=20, ge=1, le=1200)

    @model_validator(mode="after")
    def unique_tokens(self):
        if len(self.tokens) != len(self.players):
            raise ValueError("matching player and token rosters are required")
        if self.ruleset == "build_castles" and len(self.players) != 2:
            raise ValueError("castle-building requires two players")
        if len(set(self.tokens)) != len(self.tokens):
            raise ValueError("player tokens must be distinct")
        if self.player_ratings is not None:
            slots = [p.slot for p in self.player_ratings.players]
            if len(set(slots)) != len(slots) or any(slot >= len(self.players) for slot in slots):
                raise ValueError("ratings require unique seats within the player roster")
        return self
