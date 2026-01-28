import 'package:flutter/material.dart';

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
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: jobs.length,
              itemBuilder: (c, i) {
                final job = jobs[i];
                return ListTile(
                  title: Text(job['job_id']),
                  subtitle: Text(
                    '${job['status']} | ${job['phase']} | ${job['progress']}% | ${job['mode']}',
                  ),
                );
              },
            ),
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: onRefreshJobs,
                child: const Text('Refresh'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onResumeJob,
                child: const Text('Resume Selected'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onDeleteJob,
                child: const Text('Delete Selected'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
