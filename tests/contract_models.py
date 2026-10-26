"""Pure-Python contract models for boundary cases.

These models exercise the intended policies, not Objective-C runtime behavior.
The actual Logos hooks still require a cloud build and device validation.
"""
import unittest

FINGERPRINT = (
    "SileoDepiction: "
    "https://lclrc.github.io/repo/depictions/native/com.lclrc.controltab/depiction.json"
)


def package_record_gate(status, package="com.lclrc.controltab", fingerprint=FINGERPRINT):
    normalized = status.replace("\r\n", "\n")
    for record in normalized.split("\n\n"):
        is_target = False
        has_fingerprint = False
        for line in record.split("\n"):
            if line.startswith("Package:"):
                is_target = line[8:].strip() == package
            elif line == fingerprint:
                has_fingerprint = True
        if is_target and has_fingerprint:
            return True
    return False


def inject_once(items, marker):
    cleaned = [item for item in items if item[0] is not marker]
    count = len(cleaned)
    index = max(0, count - 3)
    cleaned.insert(index, (marker, "ControlTab"))
    return cleaned


class MaintenanceContractModels(unittest.TestCase):
    def test_package_field_must_be_in_target_record(self):
        status = (
            "Package: unrelated\nDescription: " + FINGERPRINT + "\n\n"
            "Package: com.lclrc.controltab\nVersion: 1.0.1~dev1\n"
        )
        self.assertFalse(package_record_gate(status))

    def test_exact_target_record_passes_with_crlf(self):
        status = "Package: com.lclrc.controltab\r\n" + FINGERPRINT + "\r\n"
        self.assertTrue(package_record_gate(status))

    def test_similar_or_continued_field_does_not_pass(self):
        status = (
            "Package: com.lclrc.controltab\n"
            "Description: " + FINGERPRINT + "\n"
        )
        self.assertFalse(package_record_gate(status))

    def test_set_items_is_idempotent_and_preserves_other_items(self):
        marker = object()
        original = [(None, "back"), (None, "forward"), (None, "share"), (None, "tabs")]
        expected = inject_once(original, marker)
        for _ in range(12):
            expected = inject_once(expected, marker)
            self.assertEqual(sum(owner is marker for owner, _ in expected), 1)
            self.assertEqual([v for owner, v in expected if owner is not marker],
                             ["back", "forward", "share", "tabs"])

    def test_empty_and_short_items_are_safe(self):
        marker = object()
        for initial in ([], [(None, "only")], [(None, "one"), (None, "two")]):
            result = inject_once(initial, marker)
            self.assertEqual(sum(owner is marker for owner, _ in result), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
