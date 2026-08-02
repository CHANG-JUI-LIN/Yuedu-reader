export interface TransactionDates {
  expiresDate?: number;
  revocationDate?: number;
}

export interface BindableTransaction {
  productId?: string;
  appAccountToken?: string;
  environment?: unknown;
}

/**
 * The only StoreKit environment whose transactions are real money.
 *
 * A TestFlight build purchases through Sandbox, where every purchase is free.
 * Accepting one as a grant let any tester unlock Pro on the App Store build
 * just by signing into the same Yuedu account — and because a Sandbox lifetime
 * binding carries `expiresAt: null`, it never aged out. The iOS client already
 * refused Sandbox transactions in release builds
 * (`SubscriptionEntitlementFilter`); this is that same rule on the server,
 * which is the side that actually granted the entitlement.
 */
export const productionEnvironment = "Production";

export interface EntitlementBinding {
  active?: boolean;
  environment?: string;
  expiresAt?: {toMillis(): number} | null;
}

export function bindingGrantsEntitlement(
  binding: EntitlementBinding,
  now = Date.now()
): boolean {
  if (binding.environment !== productionEnvironment) return false;
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
  // Refuse at the door, not just when computing the entitlement: a Sandbox
  // (TestFlight) purchase costs nothing, so binding one would keep handing out
  // Pro to anyone who tested a beta build.
  if (String(transaction.environment) !== productionEnvironment) {
    throw new Error("Only App Store purchases can be bound");
  }
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
