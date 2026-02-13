/**
 * Base provider interface.
 * All search providers extend this and implement search().
 */
export class BaseProvider {
  constructor(name) {
    this._name = name;
  }

  getName() {
    return this._name;
  }

  isAvailable() {
    return false;
  }

  /**
   * @param {string} query — sanitized search query
   * @param {number} maxResults — max sources to return
   * @returns {Promise<{summary: string, sources: Array<{title: string, url: string}>}>}
   */
  async search(_query, _maxResults) {
    throw new Error(`${this._name}: search() not implemented`);
  }
}
