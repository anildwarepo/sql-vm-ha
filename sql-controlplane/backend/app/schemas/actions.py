"""Request models for write actions."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ConfirmRequest(BaseModel):
    confirm: bool = Field(False, description="false = preview only; true = execute (requires write actions enabled)")


class InstallPatchesRequest(ConfirmRequest):
    classifications: list[str] | None = Field(
        None, examples=[["Critical", "Security"]],
        description="Windows update classifications. Default: all except FeaturePack/Tools.")
    kb_include: list[str] | None = Field(None, examples=[["5122768"]], description="Only these KBs (digits only)")
    kb_exclude: list[str] | None = None
    max_duration_hours: float = Field(2.0, ge=0.5, le=3.9)
    reboot_setting: Literal["IfRequired", "Never", "Always"] = "IfRequired"
    failover_first: bool = Field(False, description="If the node is the AG primary, fail over to a ready partner first")


class FailoverRequest(ConfirmRequest):
    target_instance: str = Field(description="Arc SQL instance that should become primary", examples=["SQL-VM-2"])
    ag_name: str | None = Field(None, description="Required when the instance hosts several AGs")
