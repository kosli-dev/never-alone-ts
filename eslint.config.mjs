import tseslint from "typescript-eslint";

export default [
  { files: ["**/*.{js,mjs,cjs,ts}"] },
  ...tseslint.configs.recommended,
  {
    rules: {
      "@typescript-eslint/no-explicit-any": "off",
      "@typescript-eslint/no-unused-vars": "off"
    }
  },
  {
    ignores: [
      ".gitignore",
      ".eslintrc",
      "package.json",
      "package-lock.json",
      "jest.config.js",
      "webpack.config.cjs",
      "**/dist/**",
      "**/index.js",
      "**/server.js",
      "eslint.config.mjs",
      "**/coverage/**"
    ]
  }
];
