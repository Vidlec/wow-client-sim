// Lua files imported as text (with { type: "text" }): the scenario API's definitions, which `addonsim docs` prints
declare module "*.lua" {
  const text: string;
  export default text;
}
