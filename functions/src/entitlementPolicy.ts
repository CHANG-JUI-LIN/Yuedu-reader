export interface TransactionDates {
  expiresDate?: number;
  revocationDate?: number;
}

export interface BindableTransaction {
  productId?: string;
  appAccountToken?: string;
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
