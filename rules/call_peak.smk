rule genrich_pileup:
    input:
        expand("{result_dir}/{dedup_dir}/{{sample}}-{{assembly}}.bam", **config)
    output:
        bedgraphish=expand("{result_dir}/genrich/{{sample}}-{{assembly}}.bdgish", **config),
        log=expand("{result_dir}/genrich/{{sample}}-{{assembly}}.log", **config)
    log:
        expand("{log_dir}/genrich_pileup/{{sample}}-{{assembly}}_pileup.log", **config)
    benchmark:
        expand("{benchmark_dir}/genrich_pileup/{{sample}}-{{assembly}}.benchmark.txt", **config)[0]
    conda:
        "../envs/call_peak.yaml"
    params:
        config['peak_caller'].get('genrich', " ")
    threads: 15
    shell:
        "Genrich -X -t {input} -f {output.log} -k {output.bedgraphish} {params} -v > {log} 2>&1"


rule call_peak_genrich:
    input:
        log=expand("{result_dir}/genrich/{{sample}}-{{assembly}}.log", **config)
    output:
        narrowpeak= expand("{result_dir}/genrich/{{sample}}-{{assembly}}_peaks.narrowPeak", **config)
    log:
        expand("{log_dir}/call_peak_genrich/{{sample}}-{{assembly}}_peak.log", **config)
    benchmark:
        expand("{benchmark_dir}/call_peak_genrich/{{sample}}-{{assembly}}.benchmark.txt", **config)[0]
    conda:
        "../envs/call_peak.yaml"
    params:
        config['peak_caller'].get('genrich', "")
    threads: 1
    shell:
        "Genrich -P -f {input.log} -o {output.narrowpeak} {params} -v > {log} 2>&1"


config['macs2_types'] = ['control_lambda.bdg', 'summits.bed', 'peaks.narrowPeak',
                         'peaks.xls', 'treat_pileup.bdg']
def get_fastqc(wildcards):
    if config['layout'][wildcards.sample] == "SINGLE":
        return expand("{result_dir}/{trimmed_dir}/SE/{{sample}}_trimmed_fastqc.zip", **config)
    return sorted(expand("{result_dir}/{trimmed_dir}/PE/{{sample}}_{fqext1}_trimmed_fastqc.zip", **config))

rule call_peak_macs2:
    #
    # Calculates genome size based on unique kmers of average length
    #
    input:
        bam=   expand("{result_dir}/{dedup_dir}/{{sample}}-{{assembly}}.bam", **config),
        fastqc=get_fastqc
    output:
        expand("{result_dir}/macs2/{{sample}}-{{assembly}}_{macs2_types}", **config)
    log:
        expand("{log_dir}/call_peak_macs2/{{sample}}-{{assembly}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/call_peak_macs2/{{sample}}-{{assembly}}.benchmark.txt", **config)[0]
    params:
        name=lambda wildcards, input: f"{wildcards.sample}" if config['layout'][wildcards.sample] == 'SINGLE' else \
                                      f"{wildcards.sample}_{config['fqext1']}",
        genome=f"{config['genome_dir']}/{{assembly}}/{{assembly}}.fa",
        macs_params=config['peak_caller']['macs2']
    conda:
        "../envs/call_peak_macs2.yaml"
    shell:
        f"""
        # extract the kmer size, and get the effective genome size from it
        kmer_size=$(unzip -p {{input.fastqc}} {{params.name}}_trimmed_fastqc/fastqc_data.txt  | grep -P -o '(?<=Sequence length\\t).*' | grep -P -o '\d+$');
        GENSIZE=$(unique-kmers.py {{params.genome}} -k $kmer_size --quiet 2>&1 | grep -P -o '(?<=\.fa: ).*');
        echo "kmer size: $kmer_size, and effective genome size: $GENSIZE" >> {{log}}

        # call peaks
        macs2 callpeak -t {{input.bam}} --outdir {config['result_dir']}/macs2/ -n {{wildcards.sample}}-{{wildcards.assembly}} \
        {{params.macs_params}} -g $GENSIZE > {{log}} 2>&1
        """


rule featureCounts:
    # https://www.biostars.org/p/337872/
    # https://www.biostars.org/p/228636/
    input:
        bam=expand("{result_dir}/{dedup_dir}/{{sample}}-{{assembly}}.bam", **config),
        peak=expand("{result_dir}/{{peak_caller}}/{{sample}}-{{assembly}}_peaks.narrowPeak", **config)
    output:
        tmp_saf=temp(expand("{result_dir}/{{peak_caller}}/{{sample}}-{{assembly}}.saf", **config)),
        real_out=expand("{result_dir}/{{peak_caller}}/{{sample}}-{{assembly}}_featureCounts.txt", **config),
        summary=expand("{result_dir}/{{peak_caller}}/{{sample}}-{{assembly}}_featureCounts.txt.summary", **config)
    log:
        expand("{log_dir}/featureCounts/{{sample}}-{{assembly}}-{{peak_caller}}.log", **config)
    threads: 4
    conda:
        "../envs/call_peak.yaml"
    shell:
        """
        ## Make a custom "SAF" file which featureCounts needs:
        awk 'BEGIN{{FS=OFS="\t"; print "GeneID\tChr\tStart\tEnd\tStrand"}}{{print $4, $1, $2+1, $3, "."}}' {input.peak} 1> {output.tmp_saf} 2> {log}

        ## run featureCounts
        featureCounts -T {threads} -p -a {output.tmp_saf} -F SAF -o {output.real_out} {input.bam} > {log} 2>&1
        """