#!/usr/bin/env python3
"""Static maintenance contract for ControlTab.

This is intentionally a source/package contract, not a substitute for iOS
runtime validation. It must run without Theos or an Apple SDK.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Tweak.xm").read_text(encoding="utf-8")
makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
control = (ROOT / "control").read_text(encoding="utf-8")
workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")

errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

fingerprint = (
    "SileoDepiction: "
    "https://lclrc.github.io/repo/depictions/native/com.lclrc.controltab/depiction.json"
)
require(fingerprint in source, "source fingerprint is missing")
require(fingerprint in control, "control fingerprint is missing")
require(source.count(fingerprint) == 1, "source fingerprint is not unique")
require(control.count(fingerprint) == 1, "control fingerprint is not unique")

require("gToolbarItems" not in source, "process-wide toolbar item state returned")
require("CTRemoveInjectedButtons" in source, "idempotent removal helper is missing")
require("objc_setAssociatedObject" in source, "button ownership marker is missing")
require("objc_getAssociatedObject" in source, "button ownership marker lookup is missing")
require("[mutableItems release];" in source, "local mutable items are not released")
require("class_getInstanceMethod" in source, "runtime capability gate is missing")
require("CTRequiredSafariAPIsPresent" in source, "runtime capability gate function is missing")
require("CTMethodHasShape" in source and "method_getNumberOfArguments" in source,
        "private method ABI-shape checks are missing")
require("method_getReturnType" in source and "method_getArgumentType" in source,
        "private method return/argument checks are missing")
require("#if CT_DIAGNOSTICS" in source and "CT_DIAGNOSTICS" in makefile,
        "opt-in startup diagnostics are missing")
require('isEqualToString:@"com.lclrc.controltab"' in source,
        "status check is not scoped to the installed package record")
require("hasExpectedDepiction" in source,
        "status check does not require the expected field in the same record")
require('ivar_getTypeEncoding(ivar)' in source and 'ivarType[0] == \'@\'' in source,
        "private controller ivar is not checked for object type")
set_items = source.split("- (void)setItems:(NSArray *)items", 1)[1].split("// 单击垃圾桶", 1)[0]
require(set_items.find("CTRemoveInjectedButtons(mutableItems)") < set_items.find("insertObject:trashItem"),
        "existing marked buttons are not removed before inserting a new one")
require("navigationBarURLWasTapped" in source and "respondsToSelector" in source,
        "address-bar selector call lacks an explicit capability check")

require("THEOS_PACKAGE_SCHEME = roothide" in makefile, "roothide package scheme is not enabled")
require("ControlTab_LDFLAGS = -lroothide" in makefile, "libroothide is not linked")
require("TARGET = iphone:clang:16.5:15.0" in makefile,
        "build target is not pinned to clang 16.5 / minimum iOS 15")
require("latest" not in makefile.lower(), "floating 'latest' toolchain remains in Makefile")
require("Bundles" in plist and "com.apple.mobilesafari" in plist,
        "Safari injection filter changed unexpectedly")
require("      - main" in workflow and "maintenance/phase1" not in workflow,
        "workflow triggers are not aligned to the single main branch")

fields = {}
for line in control.splitlines():
    if not line.strip() or line[0].isspace() or ":" not in line:
        continue
    key, value = line.split(":", 1)
    fields.setdefault(key, []).append(value.strip())
for key in ("Package", "Version", "Architecture", "Firmware", "SileoDepiction"):
    require(len(fields.get(key, [])) == 1, f"control must contain exactly one {key} field")
require(fields.get("Package") == ["com.lclrc.controltab"], "package identity changed")
require(fields.get("Version") == ["1.0.1~dev1"], "maintenance version is not 1.0.1~dev1")
require(fields.get("Architecture") == ["iphoneos-arm64e"], "package architecture changed")
require(fields.get("Firmware") == [">= 15.0"], "minimum firmware field changed")

if errors:
    for error in errors:
        print("FAIL: " + error, file=sys.stderr)
    raise SystemExit(1)
print("PASS: ControlTab source/package maintenance contract")
