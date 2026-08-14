const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"],
  moduleNameMapper: {
    // sfdx-lwc-jest が標準スタブを持たないモジュールを自前のモックに解決する
    "^lightning/platformResourceLoader$":
      "<rootDir>/force-app/test/jest-mocks/lightning/platformResourceLoader",
    "^lightning/actions$":
      "<rootDir>/force-app/test/jest-mocks/lightning/actions"
  }
};
