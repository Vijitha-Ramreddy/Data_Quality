export interface SapAdapter {
  syncOrder(id: string): Promise<unknown>
  getMaterialStock(materialNo: string): Promise<number>
  getPRPOStatus(reference: string): Promise<string>
  postGoodsReceipt(receiptId: string): Promise<unknown>
  postDispatch(dispatchId: string): Promise<unknown>
}

export const mockSapAdapter: SapAdapter = {
  async syncOrder(id) { return { id, status: 'synced' } },
  async getMaterialStock() { return 0 },
  async getPRPOStatus(reference) { return `Status unavailable for ${reference}` },
  async postGoodsReceipt(receiptId) { return { receiptId, status: 'posted' } },
  async postDispatch(dispatchId) { return { dispatchId, status: 'posted' } },
}
