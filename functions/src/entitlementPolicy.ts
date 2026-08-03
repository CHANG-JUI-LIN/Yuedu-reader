export interface TransactionDates {
  expiresDate?: number;
  revocationDate?: number;
}

export interface BindableTransaction {
  productId?: string;
  appAccountToken?: string;
  environment?: unknown;
}

/** App Store purchases: real money, unlock the App Store build. */
export const productionEnvironment = "Production";
/** TestFlight purchases: free, unlock the TestFlight build only. */
export const sandboxEnvironment = "Sandbox";

export interface EntitlementBinding {
  active?: boolean;
  environment?: string;
  expiresAt?: {toMillis(): number} | null;
}

/**
 * Whether a stored binding grants Pro *in the given environment*.
 *
 * TestFlight and App Store entitlements are deliberately not interchangeable.
 * A TestFlight build purchases through Sandbox, where everything is free, so
 * counting a Sandbox binding towards the Production entitlement handed out Pro
 * for nothing — and because a Sandbox lifetime binding carries
 * `expiresAt: null`, it never aged out either. Splitting by environment instead
 * of rejecting Sandbox keeps both builds purchasable while neither inherits the
 * other's Pro.
 */
export function bindingGrantsEntitlement(
  binding: EntitlementBinding,
  environment: string,
  now = Date.now()
): boolean {
  if (binding.environment !== environment) return false;
  if (binding.active !== true) return false;
  return binding.expiresAt === null ||
    binding.expiresAt === undefined ||
    binding.expiresAt.toMillis() > now;
}

interface EnvironmentPayload {
  environment?: unknown;
  data?: {
    environment?: unknown;
  };
}

const supportedProductIds = new Set([
  "com.zhangruilin.yuedureader.pro.lifetime",
  "com.zhangruilin.yuedureader.pro.monthly",
]);

export function effectiveEntitlement(
  storeKitIsActive: boolean,
  accountIsActive: boolean
): boolean {
  return storeKitIsActive || accountIsActive;
}

export function environmentName(payload: EnvironmentPayload): string | undefined {
  const value = payload.environment ?? payload.data?.environment;
  return typeof value === "string" ? value : undefined;
}

export function assertBindingOwner(
  existingUid: string | undefined,
  requestedUid: string
): void {
  if (existingUid !== undefined && existingUid !== requestedUid) {
    throw new Error("Purchase is already bound to another account");
  }
}

export function assertTransactionCanBind(
  transaction: BindableTransaction,
  accountToken: string
): void {
  if (transaction.productId === undefined || !supportedProductIds.has(transaction.productId)) {
    throw new Error("Unsupported product");
  }
  // Environment is deliberately NOT rejected here. A TestFlight tester must be
  // able to buy and have it bound, otherwise nothing unlocks for them at all.
  // The binding records which environment it came from, and
  // `bindingGrantsEntitlement` keeps the two entitlements apart when computing.
  if (
    transaction.appAccountToken !== undefined &&
    transaction.appAccountToken.toLowerCase() !== accountToken.toLowerCase()
  ) {
    throw new Error("Purchase belongs to a different app account");
  }
}

export function transactionIsActive(
  transaction: TransactionDates,
  now = Date.now()
): boolean {
  if (transaction.revocationDate !== undefined) {
    return false;
  }
  return transaction.expiresDate === undefined || transaction.expiresDate > now;
}
