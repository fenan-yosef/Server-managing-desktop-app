import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class JobsTab extends StatelessWidget {
  final List<Map<String, dynamic>> jobs;
  final Future<void> Function() onRefreshJobs;
  final VoidCallback onResumeJob;
  final VoidCallback onDeleteJob;

  const JobsTab({
    super.key,
    required this.jobs,
    required this.onRefreshJobs,
    required this.onResumeJob,
    required this.onDeleteJob,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(
                'Background Jobs',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Spacer(),
              IconButton.filledTonal(
                onPressed: onRefreshJobs,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh List',
              ),
            ],
          ),
        ),
        Expanded(
          child: jobs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.task, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text('No active jobs'),
                    ],
                  ).animate().fade(),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: jobs.length,
                  itemBuilder: (c, i) {
                    final job = jobs[i];
                    final status = job['status'] as String? ?? 'Pending';
                    final progress = job['progress'] ?? 0;
                    Color statusColor;
                    switch (status.toLowerCase()) {
                      case 'running':
                        statusColor = Colors.green;
                        break;
                      case 'failed':
                        statusColor = Colors.red;
                        break;
                      case 'paused':
                        statusColor = Colors.orange;
                        break;
                      default:
                        statusColor = Colors.grey;
                    }

                    return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Job ID: ${job['job_id']}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: statusColor.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: statusColor),
                                      ),
                                      child: Text(
                                        status.toUpperCase(),
                                        style: TextStyle(
                                          color: statusColor,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text('Phase: ${job['phase'] ?? 'Unknown'}'),
                                Text('Mode: ${job['mode'] ?? 'N/A'}'),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: LinearProgressIndicator(
                                        value: (progress is num)
                                            ? progress / 100
                                            : 0,
                                        backgroundColor: Theme.of(
                                          context,
                                        ).dividerColor,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text('$progress%'),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        )
                        .animate()
                        .fade(duration: 400.ms, delay: (100 * i).ms)
                        .slideX();
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 5,
                offset: const Offset(0, -3),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: onResumeJob,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume Selected'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                ),
                onPressed: onDeleteJob,
                icon: const Icon(Icons.delete),
                label: const Text('Delete Selected'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
