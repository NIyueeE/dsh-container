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
      body: "Provides the launch-token handoff to Caddy, hides the settings-document button in headless environments, and serves client images extracted at build time. It is built into the image and always enabled.",
      project: "Project address"
    };
    const zh = {
      title: "容器适配",
      summary: "镜像运行所需的运行期适配。",
      body: "负责把 launch token 交给 Caddy、在无桌面环境中隐藏设置文档按钮，并提供构建期抽出的客户端图片。随镜像内置，始终启用。",
      project: "项目地址"
    };
    function makeCard(t) {
      return function ContainerAdaptCard({ view }) {
        if (view === "summary") return React.createElement("span", null, t("summary"));
        return React.createElement(
          "div",
          null,
          React.createElement("p", null, t("body")),
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
