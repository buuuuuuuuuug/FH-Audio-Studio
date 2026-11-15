import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_tooltip.dart';

const rvcParameterHelp = <String, String>{
  'device': 'CPU 兼容性较好，但转换通常较慢；CUDA 使用 NVIDIA 显卡，需要对应依赖和驱动。切换设备后音色和转换参数保留。',
  'f0_method':
      'RMVPE 适合作为默认音高提取方法；Harvest 通常较慢，可比较低音效果；PM 较快，但复杂音高时可能不稳定。当前只提供这三种方法。',
  'pitch': '按半音调整音高，12 半音为一个八度；0 保留原音高起伏。音高调整不等于更换音色，应试听后决定。',
  'speaker_id': '多说话人模型中的目标说话人编号；单说话人模型通常为 0。编号必须在该模型实际支持的范围内。',
  'index_rate':
      '控制配套索引特征的混合比例。0 不使用检索；提高可减少原说话人音色残留，但也可能带入训练录音的瑕疵。没有索引时实际按 0 处理。',
  'protect': '保护清辅音和呼吸等非浊音细节，减少电音或断裂。较小数值加强保护；0.5 关闭保护。此参数不是整体降噪强度。',
  'rms_mix_rate': '控制结果的响度起伏：0 更贴近源音频的音量包络，1 保留转换结果自身的音量包络；不会改变全局音量滑杆。',
  'filter_radius':
      '仅对 Harvest 提取的音高进行中值滤波；大于等于 3 时启用，用于缓解局部音高异常。使用 RMVPE 或 PM 时不生效。',
};
const gptParameterHelp = <String, String>{
  'speed_factor': '控制生成语速；1 为正常速度，大于 1 加快，小于 1 放慢。语速过快或过慢可能影响自然度。',
  'seed': '随机种子用于控制生成随机性；-1 每次随机。同一配置和种子便于比较结果，但不同设备或运行环境仍可能产生差异。',
  'top_k': '采样时保留概率最高的 K 个候选。较小通常更集中，较大增加变化；与 Top P 和 Temperature 共同影响生成。',
  'top_p': '按累计概率保留候选，范围为 0～1。较小限制候选范围，1 不额外进行这项截断。',
  'temperature': '调整采样概率分布的平滑程度；较低通常更保守，较高增加变化。更高不代表音质一定更好。',
  'repetition_penalty': '抑制语音语义采样中的重复；1 不额外惩罚。过高可能影响正常发音或流畅度。',
  'fragment_interval': '分段生成后在音频片段之间插入的静音时长，单位为秒。文本未切分时可能没有可插入的片段间隔。',
  'text_split_method': '生成前将文本按所选规则切分为片段。较长文本可分段处理；切分方式会影响停顿与上下文衔接。',
  'sample_steps': '流匹配模型的采样步数；增加步数通常增加耗时，改善程度取决于模型。仅部分模型版本提供此参数。',
  'cfg_rate': '控制模型的条件引导强度，影响生成结果对条件的遵循程度；仅支持的模型版本生效。',
  'batch_size': '每批并行处理的文本片段数量；增大可能提高吞吐，也会增加内存或显存占用。',
  'batch_threshold': '控制片段分批的阈值，用于在批处理效率与片段长度匹配之间权衡；不确定时保留默认。',
  'device': '本地推理使用 CPU 或 NVIDIA CUDA。连接已有 API 时，设备由该 API 的启动配置决定。',
  'is_half': '使用半精度计算以减少显存占用；需要设备和模型支持。已有 API 的精度由其启动配置决定。',
  'parallel_infer': '允许并行推理以提高处理效率；实际收益和资源占用取决于模型与设备。',
  'split_bucket': '按片段长度分桶，减少同一批次的长度差异，以改善批处理效率。',
  'super_sampling': '仅对应版本支持的音频超采样选项，启用后增加处理耗时；不等同于更换生成模型。',
};

class SpeechParameterLabel extends StatelessWidget {
  const SpeechParameterLabel({
    super.key,
    required this.label,
    required this.help,
    this.size = 11.5,
    this.color,
  });
  final String label, help;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => RmTooltip(
    message: help,
    waitDuration: const Duration(milliseconds: 600),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.sans(size, color: color ?? context.rm.fg2),
          ),
        ),
        const SizedBox(width: 4),
        RmIcon('info', size: 11, color: context.rm.fg4),
      ],
    ),
  );
}
