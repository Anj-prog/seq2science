rule bedgraphish_to_bedgraph:
    """
    Convert the bedgraph-ish file generated by genrich into true bedgraph file.
    """
    input:
        expand("{result_dir}/genrich/{{assembly}}-{{sample}}.bdgish", **config)
    output:
        bedgraph=temp(expand("{result_dir}/genrich/{{assembly}}-{{sample}}.bedgraph", **config))
    log:
        expand("{log_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}.log", **config)[0]
    shell:
        """
        splits=$(grep -Pno "([^\/]*)(?=\.bam)" {input})
        splits=($splits)
        lncnt=$(wc -l {input} | echo "$(grep -Po ".*(?=\ )")":)
        splits+=($lncnt)

        counter=1
        for split in "${{splits[@]::${{#splits[@]}}-1}}";
        do
            filename=$(grep -Po "(?<=:).*" <<< $split);
            if [[ $filename =~ {wildcards.sample} ]]; then
                startnr=$(grep -Po ".*(?=\:)" <<< $split);
                endnr=$(grep -Po ".*(?=\:)" <<< ${{splits[counter]}});

                lines="NR>=startnr && NR<=endnr {{ print \$1, \$2, \$3, \$4 }}"
                lines=${{lines/startnr/$((startnr + 2))}}
                lines=${{lines/endnr/$((endnr - 1))}}

                awk "$lines" {input} > {output}
            fi
            ((counter++))
        done
        """


def find_bedgraph(wildcards):
    if wildcards.peak_caller == 'genrich':
        suffix = '.bedgraph'
    elif wildcards.peak_caller == 'macs2':
        suffix = '_treat_pileup.bdg'
    else:
        suffix = '.bedgraph'

    return f"{config['result_dir']}/{wildcards.peak_caller}/{wildcards.assembly}-{wildcards.sample}{suffix}"


rule bedgraph_bigwig:
    """
    Convert a bedgraph file into a bigwig.
    """
    input:
        bedgraph=find_bedgraph,
        genome_size=expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config)
    output:
        out=expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bw", **config),
        tmp=temp(expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bedgraphtmp", **config))
    log:
        expand("{log_dir}/bedgraph_bigwig/{{peak_caller}}/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}-{{peak_caller}}.log", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        awk -v OFS='\\t' '{{print $1, $2, $3, $4}}' {input.bedgraph} | sed '/experimental/d' |
        bedSort /dev/stdin {output.tmp} > {log} 2>&1;
        bedGraphToBigWig {output.tmp} {input.genome_size} {output.out} >> {log} 2>&1
        """


def get_bigpeak_columns(wildcards):
    if get_ftype(wildcards.peak_caller) == "narrowPeak":
        return 10
    if get_ftype(wildcards.peak_caller) == "broadPeak":
        if len(treps_from_brep[(wildcards.sample, wildcards.assembly)]) == 1:
            return 9
        return 12
    raise NotImplementedError()


def get_bigpeak_type(wildcards):
    if get_ftype(wildcards.peak_caller) == "narrowPeak":
        return "bed6+4"
    if get_ftype(wildcards.peak_caller) == "broadPeak":
        if len(treps_from_brep[(wildcards.sample, wildcards.assembly)]) == 1:
            return "bed6+3"
        return "bed12"
    raise NotImplementedError()


def get_bigpeak_schema(wildcards):
    if get_ftype(wildcards.peak_caller) == "narrowPeak":
        return f"{config['rule_dir']}/../schemas/bignarrowPeak.as"
    if get_ftype(wildcards.peak_caller) == "broadPeak":
        if len(treps_from_brep[(wildcards.sample, wildcards.assembly)]) == 1:
            return f"{config['rule_dir']}/../schemas/bigbroadPeak.as"
        return f"{config['rule_dir']}/../schemas/bigBed.as"
    raise NotImplementedError()


rule peak_bigpeak:
    """
    Convert a narrowpeak file into a bignarrowpeak file.
    https://genome-source.gi.ucsc.edu/gitlist/kent.git/tree/master/src/hg/lib/
    """
    input:
        narrowpeak=expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}_peaks.{{peak}}", **config),
        genome_size=expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config)
    output:
        out=temp(expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.big{{peak}}", **config)),
        tmp=temp(expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.tmp.{{peak}}", **config))
    log:
        expand("{log_dir}/narrowpeak_bignarrowpeak/{{peak_caller}}/{{assembly}}-{{sample}}-{{peak}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}-{{peak_caller}}-{{peak}}.log", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    params:
        schema=lambda wildcards: get_bigpeak_schema(wildcards),
        type=lambda wildcards: get_bigpeak_type(wildcards),
        columns=lambda wildcards: get_bigpeak_columns(wildcards)
    shell:
        """
        # keep first 10 columns, idr adds extra columns we do not need for our bigpeak
        cut -d$'\t' -f 1-{params.columns} {input.narrowpeak} |
        awk -v OFS="\t" '{{$5=$5>1000?1000:$5}} {{print}}' | 
        bedSort /dev/stdin {output.tmp} > {log} 2>&1;
        bedToBigBed -type={params.type} -as={params.schema} {output.tmp} {input.genome_size} {output.out} > {log} 2>&1
        """


def get_strandedness(wildcards):
    sample = f"{wildcards.sample}"
    if 'replicate' in samples and config.get('technical_replicates') == 'merge':
        s2 = samples[['replicate', 'strandedness']].drop_duplicates().set_index('replicate')
        strandedness = s2["strandedness"].loc[sample]
    else:
        strandedness = samples["strandedness"].loc[sample]
    return strandedness


rule bam_stranded_bigwig:
    """
    Convert a bam file into two bigwig files, one for each strand    
    """
    input:
        bam=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam", **config),
        bai=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam.bai", **config)
    output:
        forwards=temp(expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.fwd.bw", **config)),
        reverses=temp(expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.rev.bw", **config))
    params:
        flags=config['deeptools'],
        strandedness=get_strandedness
    wildcard_constraints:
        sorting=config['bam_sort_order'] if config.get('bam_sort_order', False) else ""
    log:
        expand("{log_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.log", **config),
    benchmark:
        expand("{benchmark_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.benchmark.txt", **config)[0]
    conda:
        "../envs/deeptools.yaml"
    threads: 16
    resources:
        deeptools_limit=lambda wildcards, threads: threads
    shell:
        """       
        direction1=forward
        direction2=reverse
        if [ {params.strandedness} == 'reverse' ]; then
            direction1=reverse
            direction2=forward
        fi
                    
        bamCoverage --bam {input.bam} --outFileName {output.forwards} --filterRNAstrand $direction1 --numberOfProcessors {threads} {params.flags} --verbose >> {log} 2>&1 &&        
        bamCoverage --bam {input.bam} --outFileName {output.reverses} --filterRNAstrand $direction2 --numberOfProcessors {threads} {params.flags} --verbose >> {log} 2>&1
        """

rule bam_bigwig:
    """
    Convert a bam file into a bigwig file
    """
    input:
        bam=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam", **config),
        bai=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam.bai", **config)
    output:
        temp(expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bw", **config))
    params:
        config['deeptools']
    wildcard_constraints:
        sorting=config['bam_sort_order'] if config.get('bam_sort_order') else ""
    log:
        expand("{log_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.log", **config),
    benchmark:
        expand("{benchmark_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.benchmark.txt", **config)[0]
    conda:
        "../envs/deeptools.yaml"
    threads: 16
    resources:
        deeptools_limit=lambda wildcards, threads: threads
    shell:
        """
        bamCoverage --bam {input.bam} --outFileName {output} --numberOfProcessors {threads} {params} --verbose >> {log} 2>&1
        """