/** Races a promise against a timeout without leaking the losing rejection. */
export function withTimeout<T>(promise: Promise<T>, milliseconds: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_resolve, reject) => {
      setTimeout(() => reject(new Error("operation timed out")), milliseconds).unref();
    }),
  ]);
}
