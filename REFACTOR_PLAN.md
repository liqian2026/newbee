# 重构实施清单（100% 落地 DESIGN.md）

- [x] P0 调研：基线 253/280；失败集中在旧 evolution/permissions
- [x] 1. EventStore（checksum frame、单调 event_id、replay、checkpoint、durability 档位）
- [ ] 2. Environment.Store（.newbee §11.1 布局、原子写、锁、migration）
- [ ] 3. 对象模型：Release / Change / Revision / Evaluation structs
- [x] 4. PluginContract + PluginManager + PluginSupervisor（effect 登记/leak check）
- [x] 5. 内置插件 registry（Fs/Edit/.../RepoMap 全部为 plugin release）
- [x] 6. BindingCodec（白名单/tombstone）+ Generation（quiesce/snapshot/switch/drain）
- [x] 7. EvaluatorPool（generation 管理，复用 DEE.Evaluator 节点机制）
- [ ] 8. Antibodies（两态生命周期 hot/warm/cold）+ Verifier 五层 + PPT
- [ ] 9. Autonomy（档位+Ring 门+挣来的自治）+ Observation/Fitness 价签
- [ ] 10. JIT（profiling→compile→deopt 策略）
- [ ] 11. Coordinator 完整状态机（幂等、expected_version、deadline、通知）
- [ ] 12. Agent.Protocol（outbox/inbox 去重、幂等键）+ Worker/Adapter/Advisor
- [ ] 13. Projection（worker 视图、沉睡规则挂载点）
- [ ] 14. Host.Shell 类型化请求 + 受控 transport
- [x] 15. 命令层：/evolve /environment /approve /tools /dump /autonomy
- [x] 16. 删除旧旁路：Evolver/Snapshot/JIT/Policy/HotLoader/Metrics/PriceTags/Bench
- [ ] 17. 验收测试（§15 架构验收 1-12）
