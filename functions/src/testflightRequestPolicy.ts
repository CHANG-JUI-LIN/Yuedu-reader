const maxEmailLength = 254;

// Practical email validation: single @, non-empty local/domain parts, no
// spaces or slashes (slashes would break the Firestore document id), and a
// dot in the domain. Deliberately not RFC-complete — the developer re-types
// the address in App Store Connect anyway, and Apple's invite bounces
// harmlessly on a wrong address.
const emailPattern = /^[^\s@/]+@[^\s@/]+\.[^\s@/]+$/;

export function normalizeTestFlightEmail(rawValue: unknown): string | null {
  if (typeof rawValue !== "string") {
    return null;
  }
  const normalized = rawValue.trim().toLowerCase();
  if (normalized.length === 0 || normalized.length > maxEmailLength) {
    return null;
  }
  return emailPattern.test(normalized) ? normalized : null;
}
