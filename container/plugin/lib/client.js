"use strict";
window.__ModuleLoader__.load({
  id: "@dsh-container/adapt",
  factory: (require) => {
    var module = { exports: {} }, exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
    const React = require("react");
    const NS = "containerAdapt";
    const PROJECT_URL = "https://github.com/NIyueeE/dsh-container";
    const en = {
      title: "Container adaptation",
      summary: "Runtime adaptations for this container image.",
      login: "Login: hands the launch token to Caddy for the first browser sign-in redirect.",
      ui: "UI: hides the unusable “Open config file” action in headless environments.",
      assets: "Assets: serves client images extracted at build time, reducing the initial payload.",
      source: "Built into the dsh-container image",
      project: "Project address"
    };
    const zh = {
      title: "容器适配",
      summary: "镜像运行所需的运行期适配。",
      login: "登录链路：把 launch token 交给 Caddy，完成首次浏览器登录重定向。",
      ui: "界面适配：在无桌面环境中隐藏不可用的“打开配置文件”按钮。",
      assets: "资源加载：提供构建期抽出的客户端图片，减少首屏下载体积。",
      source: "随 dsh-container 镜像内置",
      project: "项目地址"
    };
    function makeCard(t) {
      return function ContainerAdaptCard({ view }) {
        if (view === "summary") return React.createElement("span", null, t("summary"));
        return React.createElement(
          "div",
          null,
          React.createElement(
            "ul",
            null,
            React.createElement("li", null, t("login")),
            React.createElement("li", null, t("ui")),
            React.createElement("li", null, t("assets"))
          ),
          React.createElement("p", null, t("source")),
          React.createElement(
            "p",
            null,
            t("project"),
            ": ",
            React.createElement("a", {
              href: PROJECT_URL,
              target: "_blank",
              rel: "noreferrer noopener"
            }, PROJECT_URL)
          )
        );
      };
    }
    const inject = ["slots", "locale"];
    function apply(ctx) {
      const t = ctx.locale.bind(NS);
      ctx.effect(() => ctx.locale.register(NS, { zh, en }), "dsh-container-adapt: dictionaries");
      const Card = makeCard(t);
      ctx.slots.inject("plugins.item", () => ctx.slots.register({
        name: "plugins.item",
        id: "dsh-container",
        order: 50,
        label: () => t("title"),
        locale: NS
      }, Card));
    }
    exports.NS = NS;
    exports.inject = inject;
    exports.apply = apply;
    return module.exports;
  }
});
